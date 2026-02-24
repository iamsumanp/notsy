import Foundation

enum AIWritingError: LocalizedError {
    case disabled
    case missingAPIKey
    case invalidRequest
    case requestFailed(String)
    case invalidResponse
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .disabled:
            return "AI is disabled. Enable it in Preferences first."
        case .missingAPIKey:
            return "Missing OpenAI API key. Add it in Preferences."
        case .invalidRequest:
            return "Could not build the AI request."
        case .requestFailed(let message):
            return "AI request failed: \(message)"
        case .invalidResponse:
            return "AI returned an unexpected response."
        case .emptyResult:
            return "AI returned an empty result."
        }
    }
}

actor AIWritingService {
    static let shared = AIWritingService()

    static let enabledDefaultsKey = "NotsyAIEnabled"
    static let modelDefaultsKey = "NotsyAIModel"
    static let defaultModel = "gpt-4.1-mini"
    static let keychainService = "com.notsy"
    static let apiKeyKeychainAccount = "openai_api_key"

    private init() {}

    func listAvailableModels(apiKey: String) async throws -> [String] {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw AIWritingError.missingAPIKey
        }
        guard let url = URL(string: "https://api.openai.com/v1/models") else {
            throw AIWritingError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIWritingError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = responseErrorMessage(from: data) ?? "HTTP \(httpResponse.statusCode)"
            throw AIWritingError.requestFailed(message)
        }

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["data"] as? [[String: Any]] else {
            throw AIWritingError.invalidResponse
        }

        let ids = rows.compactMap { $0["id"] as? String }
            .filter { isEditorModelID($0) }
        let unique = Array(Set(ids))
        let sorted = unique.sorted { lhs, rhs in
            sortRank(for: lhs) < sortRank(for: rhs)
                || (sortRank(for: lhs) == sortRank(for: rhs) && lhs.localizedStandardCompare(rhs) == .orderedAscending)
        }

        if sorted.isEmpty {
            return [Self.defaultModel]
        }
        return sorted
    }

    func rewriteSelection(selection: String, instruction: String, noteContext: String) async throws -> String {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Self.enabledDefaultsKey) else {
            throw AIWritingError.disabled
        }

        let apiKey = KeychainHelper.load(
            service: Self.keychainService,
            account: Self.apiKeyKeychainAccount
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !apiKey.isEmpty else {
            throw AIWritingError.missingAPIKey
        }

        let model = defaults.string(forKey: Self.modelDefaultsKey) ?? Self.defaultModel
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            throw AIWritingError.invalidRequest
        }

        let contextSnippet = String(noteContext.prefix(2800))
        let systemPrompt =
            "You edit user-selected note text. Return only the edited text with no preface, no markdown fence, and no quotes."
        let userPrompt = """
        Instruction:
        \(instruction)

        Selected text:
        \"\"\"
        \(selection)
        \"\"\"

        Note context:
        \"\"\"
        \(contextSnippet)
        \"\"\"
        """

        let payload: [String: Any] = [
            "model": model,
            "temperature": 0.2,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ]
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: payload)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = bodyData

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIWritingError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = responseErrorMessage(from: data) ?? "HTTP \(httpResponse.statusCode)"
            throw AIWritingError.requestFailed(message)
        }

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AIWritingError.invalidResponse
        }

        let cleaned = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw AIWritingError.emptyResult
        }
        return cleaned
    }

    private func responseErrorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let error = object["error"] as? [String: Any],
           let message = error["message"] as? String,
           !message.isEmpty {
            return message
        }
        if let message = object["message"] as? String, !message.isEmpty {
            return message
        }
        return nil
    }

    private func isEditorModelID(_ id: String) -> Bool {
        id.hasPrefix("gpt-")
            || id.hasPrefix("o1")
            || id.hasPrefix("o3")
            || id.hasPrefix("o4")
    }

    private func sortRank(for id: String) -> Int {
        if id == Self.defaultModel { return 0 }
        if id.hasPrefix("gpt-5") { return 1 }
        if id.hasPrefix("gpt-4.1") { return 2 }
        if id.hasPrefix("gpt-4o") { return 3 }
        if id.hasPrefix("o4") { return 4 }
        if id.hasPrefix("o3") { return 5 }
        if id.hasPrefix("o1") { return 6 }
        if id.hasPrefix("gpt-") { return 7 }
        return 8
    }
}
