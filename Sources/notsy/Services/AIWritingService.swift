import Foundation

struct AIInputImage: Equatable {
    let token: String
    let data: Data
    let mimeType: String
}

enum AIWritingProvider: String, CaseIterable, Identifiable {
    case openAI = "openai"
    case gemini = "gemini"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .openAI: return "OpenAI"
        case .gemini: return "Gemini"
        }
    }
}

enum AIWritingError: LocalizedError {
    case disabled
    case noEnabledProvider
    case missingAPIKey(provider: AIWritingProvider)
    case invalidRequest
    case providerFailed(provider: AIWritingProvider, message: String)
    case requestFailed(String)
    case invalidResponse
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .disabled:
            return "AI is disabled. Enable it in Preferences first."
        case .noEnabledProvider:
            return "No AI provider is enabled. Enable OpenAI or Gemini in Preferences."
        case .missingAPIKey(let provider):
            return "Missing \(provider.label) API key. Add it in Preferences."
        case .invalidRequest:
            return "Could not build the AI request."
        case .providerFailed(let provider, let message):
            return "\(provider.label) request failed: \(message)"
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
    static let providerDefaultsKey = "NotsyAIProvider"
    static let openAIEnabledDefaultsKey = "NotsyAIOpenAIEnabled"
    static let geminiEnabledDefaultsKey = "NotsyAIGeminiEnabled"
    static let modelDefaultsKey = "NotsyAIModel"
    static let geminiModelDefaultsKey = "NotsyAIGeminiModel"
    static let defaultModel = "gpt-4.1-mini"
    static let defaultGeminiModel = "gemini-2.0-flash"
    static let keychainService = "com.notsy"
    static let apiKeyKeychainAccount = "openai_api_key"
    static let geminiAPIKeyKeychainAccount = "gemini_api_key"

    private init() {}

    func listAvailableModels(apiKey: String) async throws -> [String] {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw AIWritingError.missingAPIKey(provider: .openAI)
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

    func listAvailableGeminiModels(apiKey: String) async throws -> [String] {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw AIWritingError.missingAPIKey(provider: .gemini)
        }
        guard let url = URL(
            string: "https://generativelanguage.googleapis.com/v1beta/models?key=\(trimmedKey)"
        ) else {
            throw AIWritingError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIWritingError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = responseErrorMessage(from: data) ?? "HTTP \(httpResponse.statusCode)"
            throw AIWritingError.providerFailed(provider: .gemini, message: message)
        }

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["models"] as? [[String: Any]] else {
            throw AIWritingError.invalidResponse
        }

        let ids = rows.compactMap { row -> String? in
            guard let methods = row["supportedGenerationMethods"] as? [String],
                  methods.contains("generateContent"),
                  let rawName = row["name"] as? String else {
                return nil
            }
            let normalized = rawName.replacingOccurrences(of: "models/", with: "")
            guard normalized.hasPrefix("gemini") else { return nil }
            return normalized
        }

        let unique = Array(Set(ids))
        let sorted = unique.sorted { lhs, rhs in
            geminiSortRank(for: lhs) < geminiSortRank(for: rhs)
                || (geminiSortRank(for: lhs) == geminiSortRank(for: rhs)
                    && lhs.localizedStandardCompare(rhs) == .orderedAscending)
        }
        if sorted.isEmpty {
            return [Self.defaultGeminiModel]
        }
        return sorted
    }

    func rewriteSelection(
        selection: String,
        instruction: String,
        noteContext: String,
        inputImages: [AIInputImage] = []
    ) async throws -> String {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Self.enabledDefaultsKey) else {
            throw AIWritingError.disabled
        }

        let contextSnippet = String(noteContext.prefix(2800))
        let systemPrompt = """
        You edit user-selected note text.
        Return only the edited content with no preface, no markdown fence, and no quotes.
        If the instruction asks for visual formatting (for example: bold, italic, underline, strikethrough, headings, bullets, checkboxes, links, font changes, or text color), return an HTML fragment that represents the formatted result.
        For text color, use inline CSS color styles.
        If the selected text contains tokens like [[IMAGE_1]], [[IMAGE_2]], keep those tokens exactly as-is and in place.
        If input images are attached, use them to improve factual edits and content-aware rewrites.
        If formatting is not requested, return plain text.
        """
        let imageTokenHelp = inputImages.isEmpty
            ? ""
            : "\nImage token mapping:\n" + inputImages.map { "\($0.token) -> attached image" }
                .joined(separator: "\n")
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
        \(imageTokenHelp)
        """

        let providerOrder = orderedProviders(defaults: defaults)
        guard !providerOrder.isEmpty else {
            throw AIWritingError.noEnabledProvider
        }

        var lastError: AIWritingError?
        var missingProviderKey = false

        for provider in providerOrder {
            do {
                switch provider {
                case .openAI:
                    let result = try await rewriteWithOpenAI(
                        defaults: defaults,
                        systemPrompt: systemPrompt,
                        userPrompt: userPrompt,
                        inputImages: inputImages
                    )
                    return result
                case .gemini:
                    let result = try await rewriteWithGemini(
                        defaults: defaults,
                        systemPrompt: systemPrompt,
                        userPrompt: userPrompt,
                        inputImages: inputImages
                    )
                    return result
                }
            } catch let error as AIWritingError {
                if case .missingAPIKey = error {
                    missingProviderKey = true
                }
                lastError = error
                continue
            } catch {
                lastError = .providerFailed(provider: provider, message: error.localizedDescription)
            }
        }

        if missingProviderKey {
            throw AIWritingError.requestFailed(
                "Enabled providers need valid API keys. Add keys in Preferences."
            )
        }
        if let lastError {
            throw lastError
        }
        throw AIWritingError.requestFailed("No AI provider succeeded.")
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

    private func orderedProviders(defaults: UserDefaults) -> [AIWritingProvider] {
        let preferred = AIWritingProvider(rawValue: defaults.string(forKey: Self.providerDefaultsKey) ?? "")
            ?? .openAI
        let enabled = AIWritingProvider.allCases.filter { isProviderEnabled($0, defaults: defaults) }
        guard !enabled.isEmpty else {
            return []
        }
        let others = enabled.filter { $0 != preferred }
        return enabled.contains(preferred) ? [preferred] + others : enabled
    }

    private func enabledDefaultsKey(for provider: AIWritingProvider) -> String {
        switch provider {
        case .openAI: return Self.openAIEnabledDefaultsKey
        case .gemini: return Self.geminiEnabledDefaultsKey
        }
    }

    private func isProviderEnabled(_ provider: AIWritingProvider, defaults: UserDefaults) -> Bool {
        let key = enabledDefaultsKey(for: provider)
        if defaults.object(forKey: key) == nil {
            // Backward compatibility for existing installs before per-provider toggles existed.
            return provider == .openAI && defaults.bool(forKey: Self.enabledDefaultsKey)
        }
        return defaults.bool(forKey: key)
    }

    private func rewriteWithOpenAI(
        defaults: UserDefaults,
        systemPrompt: String,
        userPrompt: String,
        inputImages: [AIInputImage]
    ) async throws -> String {
        let apiKey = KeychainHelper.load(
            service: Self.keychainService,
            account: Self.apiKeyKeychainAccount
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !apiKey.isEmpty else {
            throw AIWritingError.missingAPIKey(provider: .openAI)
        }

        let model = defaults.string(forKey: Self.modelDefaultsKey) ?? Self.defaultModel
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            throw AIWritingError.invalidRequest
        }

        var userContent: [[String: Any]] = [
            ["type": "text", "text": userPrompt]
        ]
        for image in inputImages {
            let base64 = image.data.base64EncodedString()
            let dataURL = "data:\(image.mimeType);base64,\(base64)"
            userContent.append([
                "type": "image_url",
                "image_url": ["url": dataURL]
            ])
        }

        let payload: [String: Any] = [
            "model": model,
            "temperature": 0.2,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userContent]
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
            throw AIWritingError.providerFailed(provider: .openAI, message: message)
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

    private func rewriteWithGemini(
        defaults: UserDefaults,
        systemPrompt: String,
        userPrompt: String,
        inputImages: [AIInputImage]
    ) async throws -> String {
        let apiKey = KeychainHelper.load(
            service: Self.keychainService,
            account: Self.geminiAPIKeyKeychainAccount
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !apiKey.isEmpty else {
            throw AIWritingError.missingAPIKey(provider: .gemini)
        }

        let model = defaults.string(forKey: Self.geminiModelDefaultsKey) ?? Self.defaultGeminiModel
        guard let encodedModel = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(
                string: "https://generativelanguage.googleapis.com/v1beta/models/\(encodedModel):generateContent?key=\(apiKey)"
              ) else {
            throw AIWritingError.invalidRequest
        }

        var parts: [[String: Any]] = [["text": userPrompt]]
        for image in inputImages {
            parts.append([
                "inline_data": [
                    "mime_type": image.mimeType,
                    "data": image.data.base64EncodedString()
                ]
            ])
        }

        let payload: [String: Any] = [
            "systemInstruction": ["parts": [["text": systemPrompt]]],
            "contents": [["parts": parts]],
            "generationConfig": ["temperature": 0.2]
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: payload)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = bodyData

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIWritingError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = responseErrorMessage(from: data) ?? "HTTP \(httpResponse.statusCode)"
            throw AIWritingError.providerFailed(provider: .gemini, message: message)
        }

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = object["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let content = first["content"] as? [String: Any],
              let responseParts = content["parts"] as? [[String: Any]] else {
            throw AIWritingError.invalidResponse
        }

        let text = responseParts.compactMap { $0["text"] as? String }.joined()
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw AIWritingError.emptyResult
        }
        return cleaned
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

    private func geminiSortRank(for id: String) -> Int {
        if id == Self.defaultGeminiModel { return 0 }
        if id.contains("2.5-pro") { return 1 }
        if id.contains("2.5-flash") { return 2 }
        if id.contains("2.0-flash") { return 3 }
        if id.contains("1.5-pro") { return 4 }
        if id.contains("1.5-flash") { return 5 }
        return 6
    }
}
