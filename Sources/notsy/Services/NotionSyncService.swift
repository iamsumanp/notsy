import AppKit
import Foundation

struct NotionNoteSnapshot {
    let id: UUID
    let title: String
    let plainText: String
    let attributedContent: Data
}

enum NotionNoteSyncResult {
    case synced
    case skipped
    case paused(String)
    case failed(String)
}

enum NotionConnectionCheckResult {
    case success
    case missingToken
    case invalidToken(String)
    case invalidDatabaseIDFormat
    case databaseNotAccessible(String)
    case unknownError(String)

    var message: String {
        switch self {
        case .success:
            return "Connection successful. Token is valid and database is reachable."
        case .missingToken:
            return "Add an integration secret first."
        case .invalidToken(let reason):
            return "Invalid integration secret: \(reason)"
        case .invalidDatabaseIDFormat:
            return "Database ID format is invalid. Use a 32-character hex ID from the database URL."
        case .databaseNotAccessible(let reason):
            return "Token is valid, but the database is not accessible: \(reason)"
        case .unknownError(let reason):
            return "Connection test failed: \(reason)"
        }
    }
}

actor NotionSyncService {
    static let shared = NotionSyncService()
    private static let notionAPIVersion = "2022-06-28"
    private static let notionFileUploadAPIVersion = "2025-09-03"

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

    func sync(note: NotionNoteSnapshot) async -> NotionNoteSyncResult {
        switch loadConfigState() {
        case .disabled:
            return .skipped
        case .misconfigured(let message):
            return .paused(message)
        case .ready(let config):
            do {
                let pageID = try await upsertPage(for: note, config: config)
                if pageMap[note.id.uuidString] != pageID {
                    pageMap[note.id.uuidString] = pageID
                    savePageMap()
                }
                return .synced
            } catch {
                // Keep local note edits resilient even when Notion is unavailable.
                print("Notion sync failed for note \(note.id): \(error)")
                return .failed(String(describing: error))
            }
        }
    }

    func testConnection(databaseID: String, token: String) async -> NotionConnectionCheckResult {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDatabaseID = databaseID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "")

        guard !trimmedToken.isEmpty else {
            return .missingToken
        }
        guard Self.isValidDatabaseID(normalizedDatabaseID) else {
            return .invalidDatabaseIDFormat
        }

        do {
            _ = try await request(
                method: "GET",
                path: "/v1/users/me",
                token: trimmedToken,
                body: nil
            )
        } catch let error as NotionSyncError {
            switch error {
            case .http(let message):
                return .invalidToken(message)
            case .invalidResponse(let message):
                return .unknownError(message)
            case .invalidURL:
                return .unknownError("Invalid Notion API URL")
            }
        } catch {
            return .unknownError(error.localizedDescription)
        }

        do {
            _ = try await request(
                method: "GET",
                path: "/v1/databases/\(normalizedDatabaseID)",
                token: trimmedToken,
                body: nil
            )
            return .success
        } catch let error as NotionSyncError {
            switch error {
            case .http(let message):
                return .databaseNotAccessible(message)
            case .invalidResponse(let message):
                return .unknownError(message)
            case .invalidURL:
                return .unknownError("Invalid Notion API URL")
            }
        } catch {
            return .unknownError(error.localizedDescription)
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
            try await replacePageChildren(pageID: existingPageID, note: note, config: config)
            return existingPageID
        }

        let children = try await makeChildren(from: note, token: config.token)

        let body: [String: Any] = [
            "parent": ["database_id": config.databaseID],
            "properties": [
                titlePropertyName: [
                    "title": [
                        ["type": "text", "text": ["content": safeTitle(from: note.title)]]
                    ]
                ]
            ],
            "children": children
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

    private func replacePageChildren(pageID: String, note: NotionNoteSnapshot, config: NotionConfig) async throws {
        let childIDs = try await listChildBlockIDs(pageID: pageID, token: config.token)
        for blockID in childIDs {
            _ = try await request(
                method: "DELETE",
                path: "/v1/blocks/\(blockID)",
                token: config.token,
                body: nil
            )
        }

        let children = try await makeChildren(from: note, token: config.token)
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

    private func makeChildren(from note: NotionNoteSnapshot, token: String) async throws -> [[String: Any]] {
        let segments = contentSegments(from: note)
        var children: [[String: Any]] = []

        for segment in segments {
            switch segment {
            case .text(let text):
                appendParagraphBlocks(from: text, to: &children)
            case .image(let image):
                let fileUploadID = try await uploadImage(image, token: token)
                children.append([
                    "object": "block",
                    "type": "image",
                    "image": [
                        "type": "file_upload",
                        "file_upload": ["id": fileUploadID]
                    ]
                ])
            }
            if children.count >= 100 { break }
        }

        return children
    }

    private func appendParagraphBlocks(from text: String, to children: inout [[String: Any]]) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }

        let lines = normalized.components(separatedBy: .newlines)
        for line in lines {
            let content = line.isEmpty ? " " : String(line.prefix(1800))
            children.append([
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
            ])
            if children.count >= 100 { return }
        }
    }

    private func contentSegments(from note: NotionNoteSnapshot) -> [NotionContentSegment] {
        let attributed = attributedString(from: note)
        var segments: [NotionContentSegment] = []
        var bufferedText = ""
        let fullRange = NSRange(location: 0, length: attributed.length)

        attributed.enumerateAttributes(in: fullRange) { attributes, range, _ in
            if let attachment = attributes[.attachment] as? NSTextAttachment {
                let inlineText = attributed.attributedSubstring(from: range).string
                    .replacingOccurrences(of: "\u{FFFC}", with: "")
                if !inlineText.isEmpty {
                    bufferedText += inlineText
                }

                let trimmedBuffered = bufferedText.trimmingCharacters(in: .newlines)
                if !trimmedBuffered.isEmpty {
                    segments.append(.text(bufferedText))
                }
                bufferedText = ""

                if let imageData = pngData(from: attachment) {
                    segments.append(.image(imageData))
                }
                return
            }

            bufferedText += attributed.attributedSubstring(from: range).string
        }

        let trimmedBuffered = bufferedText.trimmingCharacters(in: .newlines)
        if !trimmedBuffered.isEmpty {
            segments.append(.text(bufferedText))
        }

        if segments.isEmpty {
            return [.text(note.plainText)]
        }
        return segments
    }

    private func attributedString(from note: NotionNoteSnapshot) -> NSAttributedString {
        guard !note.attributedContent.isEmpty else { return NSAttributedString(string: note.plainText) }

        let rtfdOptions: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.rtfd
        ]
        if let attributed = try? NSAttributedString(
            data: note.attributedContent,
            options: rtfdOptions,
            documentAttributes: nil
        ) {
            return attributed
        }

        let rtfOptions: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.rtf
        ]
        if let attributed = try? NSAttributedString(
            data: note.attributedContent,
            options: rtfOptions,
            documentAttributes: nil
        ) {
            return attributed
        }

        return NSAttributedString(string: note.plainText)
    }

    private func pngData(from attachment: NSTextAttachment) -> Data? {
        if let data = attachment.fileWrapper?.regularFileContents,
           let image = NSImage(data: data) {
            return pngData(from: image)
        }
        if let image = attachment.image {
            return pngData(from: image)
        }
        return nil
    }

    private func pngData(from image: NSImage) -> Data? {
        guard let tiffData = image.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        return bitmapRep.representation(using: .png, properties: [:])
    }

    private func uploadImage(_ data: Data, token: String) async throws -> String {
        guard data.count <= 20 * 1024 * 1024 else {
            throw NotionSyncError.invalidResponse("Image exceeds Notion 20MB file upload limit")
        }

        let filename = "notsy-image-\(UUID().uuidString).png"
        let response = try await request(
            method: "POST",
            path: "/v1/file_uploads",
            token: token,
            body: [
                "mode": "single_part",
                "filename": filename,
                "content_type": "image/png"
            ],
            notionVersion: Self.notionFileUploadAPIVersion
        )

        guard let fileUploadID = response["id"] as? String else {
            throw NotionSyncError.invalidResponse("Missing file upload id")
        }

        try await sendFileUpload(
            fileUploadID: fileUploadID,
            data: data,
            filename: filename,
            contentType: "image/png",
            token: token
        )
        try await waitForFileUploadCompletion(fileUploadID: fileUploadID, token: token)
        return fileUploadID
    }

    private func sendFileUpload(fileUploadID: String, data: Data, filename: String, contentType: String, token: String) async throws {
        guard let url = URL(string: "https://api.notion.com/v1/file_uploads/\(fileUploadID)/send") else {
            throw NotionSyncError.invalidURL
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(contentType)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.notionFileUploadAPIVersion, forHTTPHeaderField: "Notion-Version")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NotionSyncError.invalidResponse("No HTTP response")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw NotionSyncError.http("File upload failed with HTTP \(httpResponse.statusCode)")
        }
    }

    private func waitForFileUploadCompletion(fileUploadID: String, token: String) async throws {
        for _ in 0..<10 {
            let response = try await request(
                method: "GET",
                path: "/v1/file_uploads/\(fileUploadID)",
                token: token,
                body: nil,
                notionVersion: Self.notionFileUploadAPIVersion
            )
            let status = response["status"] as? String
            if status == "uploaded" {
                return
            }
            if status == "failed" {
                let message = response["message"] as? String ?? "Notion file upload failed"
                throw NotionSyncError.invalidResponse(message)
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        throw NotionSyncError.invalidResponse("Timed out waiting for uploaded image")
    }

    private func safeTitle(from title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : String(trimmed.prefix(200))
    }

    private func request(
        method: String,
        path: String,
        token: String,
        body: [String: Any]?,
        notionVersion: String = NotionSyncService.notionAPIVersion
    ) async throws -> [String: Any] {
        guard let url = URL(string: "https://api.notion.com\(path)") else {
            throw NotionSyncError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(notionVersion, forHTTPHeaderField: "Notion-Version")
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

    private func loadConfigState() -> NotionConfigLoadState {
        let defaults = UserDefaults.standard
        let enabled = defaults.bool(forKey: Self.enabledDefaultsKey)
        if !enabled { return .disabled }

        let databaseIDRaw = defaults.string(forKey: Self.databaseIDDefaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let databaseID = databaseIDRaw.replacingOccurrences(of: "-", with: "")
        let oauthToken = KeychainHelper.load(
            service: Self.keychainService,
            account: Self.oauthAccessTokenKeychainAccount
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let legacyToken = KeychainHelper.load(
            service: Self.keychainService,
            account: Self.legacyTokenKeychainAccount
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let token = oauthToken.isEmpty ? legacyToken : oauthToken

        guard !databaseID.isEmpty else {
            return .misconfigured("Notion sync paused: add your database ID in Preferences.")
        }
        guard Self.isValidDatabaseID(databaseID) else {
            return .misconfigured("Notion sync paused: database ID format is invalid.")
        }
        guard !token.isEmpty else {
            return .misconfigured("Notion sync paused: add your integration secret.")
        }

        return .ready(NotionConfig(enabled: enabled, databaseID: databaseID, token: token))
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

    private static func isValidDatabaseID(_ value: String) -> Bool {
        guard value.count == 32 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 65...70, 97...102:
                return true
            default:
                return false
            }
        }
    }
}

private struct NotionConfig {
    let enabled: Bool
    let databaseID: String
    let token: String
}

private enum NotionConfigLoadState {
    case disabled
    case ready(NotionConfig)
    case misconfigured(String)
}

private enum NotionContentSegment {
    case text(String)
    case image(Data)
}

private enum NotionSyncError: Error {
    case invalidURL
    case invalidResponse(String)
    case http(String)
}
