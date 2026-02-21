import Foundation

struct NotionNoteSnapshot {
    let id: UUID
    let title: String
    let plainText: String
}

actor NotionSyncService {
    static let shared = NotionSyncService()

    static let enabledDefaultsKey = "NotsyNotionSyncEnabled"
    static let databaseIDDefaultsKey = "NotsyNotionDatabaseID"
    static let oauthClientIDDefaultsKey = "NotsyNotionOAuthClientID"
    static let oauthRedirectURIDefaultsKey = "NotsyNotionOAuthRedirectURI"
    static let keychainService = "com.notsy"
    static let oauthClientSecretKeychainAccount = "notion_oauth_client_secret"
    static let oauthAccessTokenKeychainAccount = "notion_oauth_access_token"
    static let oauthRefreshTokenKeychainAccount = "notion_oauth_refresh_token"
    static let legacyTokenKeychainAccount = "notion_api_token"

    private var pageMap: [String: String] = [:]
    private var titlePropertyNameCache: String?
    private let pageMapURL: URL

    private init() {
        let appSupportBase = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appSupportURL = appSupportBase.appendingPathComponent("Notsy")
        if !FileManager.default.fileExists(atPath: appSupportURL.path) {
            try? FileManager.default.createDirectory(at: appSupportURL, withIntermediateDirectories: true)
        }
        self.pageMapURL = appSupportURL.appendingPathComponent("notion-page-map.json")
        self.pageMap = Self.loadPageMap(from: pageMapURL)
    }

    func sync(note: NotionNoteSnapshot) async {
        guard let config = loadConfig(), config.enabled else { return }

        do {
            let pageID = try await upsertPage(for: note, config: config)
            if pageMap[note.id.uuidString] != pageID {
                pageMap[note.id.uuidString] = pageID
                savePageMap()
            }
        } catch {
            // Keep local note edits resilient even when Notion is unavailable.
            print("Notion sync failed for note \(note.id): \(error)")
        }
    }

    func buildOAuthAuthorizationURL(clientID: String, redirectURI: String, state: String) -> URL? {
        let trimmedClientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRedirectURI = redirectURI.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedClientID.isEmpty, !trimmedRedirectURI.isEmpty else { return nil }

        var components = URLComponents(string: "https://api.notion.com/v1/oauth/authorize")
        components?.queryItems = [
            URLQueryItem(name: "owner", value: "user"),
            URLQueryItem(name: "client_id", value: trimmedClientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: trimmedRedirectURI),
            URLQueryItem(name: "state", value: state)
        ]
        return components?.url
    }

    func exchangeOAuthCode(clientID: String, clientSecret: String, redirectURI: String, code: String) async throws {
        let trimmedClientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedClientSecret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRedirectURI = redirectURI.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedClientID.isEmpty,
              !trimmedClientSecret.isEmpty,
              !trimmedRedirectURI.isEmpty,
              !trimmedCode.isEmpty else {
            throw NotionSyncError.invalidResponse("Missing OAuth fields")
        }

        guard let url = URL(string: "https://api.notion.com/v1/oauth/token") else {
            throw NotionSyncError.invalidURL
        }

        let rawBasic = "\(trimmedClientID):\(trimmedClientSecret)"
        guard let basicData = rawBasic.data(using: .utf8) else {
            throw NotionSyncError.invalidResponse("Invalid OAuth credentials")
        }
        let basicAuth = basicData.base64EncodedString()

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Basic \(basicAuth)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "authorization_code",
            "code": trimmedCode,
            "redirect_uri": trimmedRedirectURI
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NotionSyncError.invalidResponse("No HTTP response")
        }

        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = (json?["message"] as? String) ?? "HTTP \(httpResponse.statusCode)"
            throw NotionSyncError.http(message)
        }

        guard let accessToken = json?["access_token"] as? String else {
            throw NotionSyncError.invalidResponse("Missing access_token")
        }
        let refreshToken = json?["refresh_token"] as? String

        guard KeychainHelper.save(
            service: Self.keychainService,
            account: Self.oauthAccessTokenKeychainAccount,
            value: accessToken
        ) else {
            throw NotionSyncError.invalidResponse("Failed to store access token")
        }

        _ = KeychainHelper.save(
            service: Self.keychainService,
            account: Self.oauthClientSecretKeychainAccount,
            value: trimmedClientSecret
        )
        if let refreshToken, !refreshToken.isEmpty {
            _ = KeychainHelper.save(
                service: Self.keychainService,
                account: Self.oauthRefreshTokenKeychainAccount,
                value: refreshToken
            )
        }
    }

    private func upsertPage(for note: NotionNoteSnapshot, config: NotionConfig) async throws -> String {
        let titlePropertyName = try await resolveTitlePropertyName(config: config)
        if let existingPageID = pageMap[note.id.uuidString] {
            try await updatePage(pageID: existingPageID, note: note, titlePropertyName: titlePropertyName, config: config)
            try await replacePageChildren(pageID: existingPageID, plainText: note.plainText, config: config)
            return existingPageID
        }

        let body: [String: Any] = [
            "parent": ["database_id": config.databaseID],
            "properties": [
                titlePropertyName: [
                    "title": [
                        ["type": "text", "text": ["content": safeTitle(from: note.title)]]
                    ]
                ]
            ],
            "children": makeChildren(from: note.plainText)
        ]

        let response = try await request(
            method: "POST",
            path: "/v1/pages",
            token: config.token,
            body: body
        )
        guard let pageID = response["id"] as? String else {
            throw NotionSyncError.invalidResponse("Missing page id in create response")
        }
        return pageID
    }

    private func updatePage(pageID: String, note: NotionNoteSnapshot, titlePropertyName: String, config: NotionConfig) async throws {
        let body: [String: Any] = [
            "properties": [
                titlePropertyName: [
                    "title": [
                        ["type": "text", "text": ["content": safeTitle(from: note.title)]]
                    ]
                ]
            ]
        ]
        _ = try await request(
            method: "PATCH",
            path: "/v1/pages/\(pageID)",
            token: config.token,
            body: body
        )
    }

    private func replacePageChildren(pageID: String, plainText: String, config: NotionConfig) async throws {
        let childIDs = try await listChildBlockIDs(pageID: pageID, token: config.token)
        for blockID in childIDs {
            _ = try await request(
                method: "DELETE",
                path: "/v1/blocks/\(blockID)",
                token: config.token,
                body: nil
            )
        }

        let children = makeChildren(from: plainText)
        guard !children.isEmpty else { return }

        _ = try await request(
            method: "PATCH",
            path: "/v1/blocks/\(pageID)/children",
            token: config.token,
            body: ["children": children]
        )
    }

    private func listChildBlockIDs(pageID: String, token: String) async throws -> [String] {
        let response = try await request(
            method: "GET",
            path: "/v1/blocks/\(pageID)/children?page_size=100",
            token: token,
            body: nil
        )

        guard let results = response["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { $0["id"] as? String }
    }

    private func resolveTitlePropertyName(config: NotionConfig) async throws -> String {
        if let titlePropertyNameCache { return titlePropertyNameCache }

        let response = try await request(
            method: "GET",
            path: "/v1/databases/\(config.databaseID)",
            token: config.token,
            body: nil
        )

        guard let properties = response["properties"] as? [String: Any] else {
            throw NotionSyncError.invalidResponse("Database properties missing")
        }

        for (propertyName, value) in properties {
            guard let valueDict = value as? [String: Any],
                  let type = valueDict["type"] as? String,
                  type == "title" else {
                continue
            }
            titlePropertyNameCache = propertyName
            return propertyName
        }

        throw NotionSyncError.invalidResponse("No title property found in database")
    }

    private func makeChildren(from plainText: String) -> [[String: Any]] {
        let normalized = plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }

        let lines = normalized.components(separatedBy: .newlines)
        var children: [[String: Any]] = []

        for line in lines {
            let content = line.isEmpty ? " " : String(line.prefix(1800))
            let block: [String: Any] = [
                "object": "block",
                "type": "paragraph",
                "paragraph": [
                    "rich_text": [
                        [
                            "type": "text",
                            "text": ["content": content]
                        ]
                    ]
                ]
            ]
            children.append(block)
            if children.count >= 100 { break }
        }

        return children
    }

    private func safeTitle(from title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : String(trimmed.prefix(200))
    }

    private func request(method: String, path: String, token: String, body: [String: Any]?) async throws -> [String: Any] {
        guard let url = URL(string: "https://api.notion.com\(path)") else {
            throw NotionSyncError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NotionSyncError.invalidResponse("No HTTP response")
        }

        let jsonObject = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = (jsonObject?["message"] as? String) ?? "HTTP \(httpResponse.statusCode)"
            throw NotionSyncError.http(message)
        }

        return jsonObject ?? [:]
    }

    private func loadConfig() -> NotionConfig? {
        let defaults = UserDefaults.standard
        let enabled = defaults.bool(forKey: Self.enabledDefaultsKey)
        let databaseID = defaults.string(forKey: Self.databaseIDDefaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let oauthToken = KeychainHelper.load(
            service: Self.keychainService,
            account: Self.oauthAccessTokenKeychainAccount
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let legacyToken = KeychainHelper.load(
            service: Self.keychainService,
            account: Self.legacyTokenKeychainAccount
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let token = oauthToken.isEmpty ? legacyToken : oauthToken

        guard !databaseID.isEmpty, !token.isEmpty else { return nil }
        return NotionConfig(enabled: enabled, databaseID: databaseID, token: token)
    }

    private static func loadPageMap(from url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func savePageMap() {
        guard let encoded = try? JSONEncoder().encode(pageMap) else { return }
        try? encoded.write(to: pageMapURL)
    }
}

private struct NotionConfig {
    let enabled: Bool
    let databaseID: String
    let token: String
}

private enum NotionSyncError: Error {
    case invalidURL
    case invalidResponse(String)
    case http(String)
}
