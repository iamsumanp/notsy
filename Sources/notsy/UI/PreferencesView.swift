import SwiftUI
import Carbon
import AppKit

struct PreferencesView: View {
    @Environment(NoteStore.self) private var store
    @State private var keyCode: UInt32
    @State private var modifiers: UInt32
    @State private var hotkeyMessage: String?
    @State private var isRecordingHotkey = false
    @State private var keyMonitor: Any?
    @State private var notionSyncEnabled: Bool
    @State private var notionDatabaseID: String
    @State private var notionIntegrationSecret: String
    @State private var notionMessage: String?
    @State private var isTestingNotionConnection = false
    @State private var notionAutosaveTask: Task<Void, Never>?
    @State private var aiEnabled: Bool
    @State private var aiProvider: AIWritingProvider
    @State private var openAIEnabled: Bool
    @State private var geminiEnabled: Bool
    @State private var aiModel: String
    @State private var geminiModel: String
    @State private var openAIAPIKey: String
    @State private var geminiAPIKey: String
    @State private var aiMessage: String?
    @State private var aiAutosaveTask: Task<Void, Never>?
    @State private var aiModelFetchTask: Task<Void, Never>?
    @State private var geminiModelFetchTask: Task<Void, Never>?
    @State private var availableAIModels: [String] = []
    @State private var availableGeminiModels: [String] = []
    @State private var isLoadingAIModels = false
    @State private var isLoadingGeminiModels = false
    @State private var loadedModelsForAPIKey: String = ""
    @State private var loadedModelsForGeminiAPIKey: String = ""
    @State private var showDeleteUnpinnedConfirmation = false
    @AppStorage("notsy.selection.color") private var selectionColorChoice: String = "blue"
    @AppStorage(Theme.themeDefaultsKey) private var themeVariantRaw: String = NotsyThemeVariant.bluish.rawValue

    init() {
        let shortcut = GlobalHotkeyManager.shared.currentShortcut
        let defaults = UserDefaults.standard
        _keyCode = State(initialValue: shortcut.keyCode)
        _modifiers = State(initialValue: shortcut.modifiers)
        _notionSyncEnabled = State(initialValue: defaults.bool(forKey: NotionSyncService.enabledDefaultsKey))
        _notionDatabaseID = State(initialValue: defaults.string(forKey: NotionSyncService.databaseIDDefaultsKey) ?? "")
        _notionIntegrationSecret = State(initialValue: KeychainHelper.load(
            service: NotionSyncService.keychainService,
            account: NotionSyncService.legacyTokenKeychainAccount
        ) ?? "")
        _aiEnabled = State(initialValue: defaults.bool(forKey: AIWritingService.enabledDefaultsKey))
        _aiProvider = State(
            initialValue: AIWritingProvider(rawValue: defaults.string(forKey: AIWritingService.providerDefaultsKey) ?? "")
                ?? .openAI
        )
        _openAIEnabled = State(
            initialValue: defaults.object(forKey: AIWritingService.openAIEnabledDefaultsKey) == nil
                ? defaults.bool(forKey: AIWritingService.enabledDefaultsKey)
                : defaults.bool(forKey: AIWritingService.openAIEnabledDefaultsKey)
        )
        _geminiEnabled = State(initialValue: defaults.bool(forKey: AIWritingService.geminiEnabledDefaultsKey))
        _aiModel = State(initialValue: defaults.string(forKey: AIWritingService.modelDefaultsKey) ?? AIWritingService.defaultModel)
        _geminiModel = State(
            initialValue: defaults.string(forKey: AIWritingService.geminiModelDefaultsKey)
                ?? AIWritingService.defaultGeminiModel
        )
        _openAIAPIKey = State(initialValue: KeychainHelper.load(
            service: AIWritingService.keychainService,
            account: AIWritingService.apiKeyKeychainAccount
        ) ?? "")
        _geminiAPIKey = State(initialValue: KeychainHelper.load(
            service: AIWritingService.keychainService,
            account: AIWritingService.geminiAPIKeyKeychainAccount
        ) ?? "")
    }

    private var currentHotkeyDisplay: String {
        hotkeyLabel(modifiers: modifiers, keyCode: keyCode)
    }

    private func startRecordingHotkey() {
        if isRecordingHotkey {
            stopRecordingHotkey(message: "Recording canceled.")
            return
        }
        isRecordingHotkey = true
        hotkeyMessage = "Press a shortcut now. Press Esc to cancel."
        installKeyMonitorIfNeeded()
    }

    private func resetDefaultHotkey() {
        let `default` = HotkeyShortcut.default
        keyCode = `default`.keyCode
        modifiers = `default`.modifiers
        let success = GlobalHotkeyManager.shared.updateShortcut(keyCode: keyCode, modifiers: modifiers)
        hotkeyMessage = success ? "Reset to default hotkey." : "Failed to register default shortcut."
    }

    private func hotkeyLabel(modifiers: UInt32, keyCode: UInt32) -> String {
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        let keyName = keyLabel(for: keyCode)
        return (parts + [keyName]).joined(separator: " ")
    }

    private func installKeyMonitorIfNeeded() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard isRecordingHotkey else { return event }

            if event.keyCode == 53 {
                stopRecordingHotkey(message: "Recording canceled.")
                return nil
            }

            let capturedModifiers = carbonModifiers(from: event.modifierFlags)
            guard capturedModifiers != 0 else {
                hotkeyMessage = "Use at least one modifier key (Cmd/Shift/Option/Control)."
                return nil
            }

            let capturedKeyCode = UInt32(event.keyCode)
            let success = GlobalHotkeyManager.shared.updateShortcut(
                keyCode: capturedKeyCode,
                modifiers: capturedModifiers
            )
            if success {
                keyCode = capturedKeyCode
                modifiers = capturedModifiers
                stopRecordingHotkey(message: "Global hotkey updated.")
            } else {
                stopRecordingHotkey(message: "Failed to register this shortcut.")
            }
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    private func stopRecordingHotkey(message: String? = nil) {
        isRecordingHotkey = false
        if let message {
            hotkeyMessage = message
        }
        removeKeyMonitor()
    }

    private func cancelRecordingIfNeeded() {
        guard isRecordingHotkey else { return }
        stopRecordingHotkey(message: "Recording canceled.")
    }

    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var value: UInt32 = 0
        if flags.contains(.command) { value |= UInt32(cmdKey) }
        if flags.contains(.shift) { value |= UInt32(shiftKey) }
        if flags.contains(.option) { value |= UInt32(optionKey) }
        if flags.contains(.control) { value |= UInt32(controlKey) }
        return value
    }

    private func keyLabel(for keyCode: UInt32) -> String {
        switch keyCode {
        case 49: return "Space"
        case 36: return "Return"
        case 53: return "Escape"
        case 48: return "Tab"
        case 51: return "Delete"
        case 123: return "Left Arrow"
        case 124: return "Right Arrow"
        case 125: return "Down Arrow"
        case 126: return "Up Arrow"
        default:
            if let scalar = Self.letterKeyMap[keyCode] {
                return scalar
            }
            return "Key \(keyCode)"
        }
    }

    private static let letterKeyMap: [UInt32: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J",
        40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T",
        32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z"
    ]

    private func persistNotionSettings(showMessage: Bool) {
        let trimmedDatabaseID = notionDatabaseID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedIntegrationSecret = notionIntegrationSecret.trimmingCharacters(in: .whitespacesAndNewlines)

        UserDefaults.standard.set(notionSyncEnabled, forKey: NotionSyncService.enabledDefaultsKey)
        UserDefaults.standard.set(trimmedDatabaseID, forKey: NotionSyncService.databaseIDDefaultsKey)

        if !trimmedIntegrationSecret.isEmpty {
            guard KeychainHelper.save(
                service: NotionSyncService.keychainService,
                account: NotionSyncService.legacyTokenKeychainAccount,
                value: trimmedIntegrationSecret
            ) else {
                notionMessage = "Failed to save Notion integration secret in Keychain."
                return
            }
        }

        guard showMessage else { return }
        if notionSyncEnabled {
            notionMessage = (trimmedDatabaseID.isEmpty || trimmedIntegrationSecret.isEmpty)
                ? "Saved. Add Database ID and Integration Secret before sync can run."
                : "Notion sync settings saved."
        } else {
            notionMessage = "Notion settings saved."
        }
    }

    private func saveNotionSettings() {
        persistNotionSettings(showMessage: true)
    }

    private func scheduleNotionAutosave() {
        notionAutosaveTask?.cancel()
        notionAutosaveTask = Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                persistNotionSettings(showMessage: false)
            }
        }
    }

    private func testNotionConnection() {
        let trimmedDatabaseID = notionDatabaseID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedIntegrationSecret = notionIntegrationSecret.trimmingCharacters(in: .whitespacesAndNewlines)

        isTestingNotionConnection = true
        notionMessage = "Testing Notion connection..."

        Task {
            let result = await NotionSyncService.shared.testConnection(
                databaseID: trimmedDatabaseID,
                token: trimmedIntegrationSecret
            )
            await MainActor.run {
                notionMessage = result.message
                isTestingNotionConnection = false
            }
        }
    }

    private func persistAISettings(showMessage: Bool) {
        let trimmedOpenAIModel = aiModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedOpenAIModel = trimmedOpenAIModel.isEmpty ? AIWritingService.defaultModel : trimmedOpenAIModel
        let trimmedGeminiModel = geminiModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedGeminiModel = trimmedGeminiModel.isEmpty ? AIWritingService.defaultGeminiModel : trimmedGeminiModel
        let trimmedOpenAIAPIKey = openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedGeminiAPIKey = geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)

        UserDefaults.standard.set(aiEnabled, forKey: AIWritingService.enabledDefaultsKey)
        UserDefaults.standard.set(aiProvider.rawValue, forKey: AIWritingService.providerDefaultsKey)
        UserDefaults.standard.set(openAIEnabled, forKey: AIWritingService.openAIEnabledDefaultsKey)
        UserDefaults.standard.set(geminiEnabled, forKey: AIWritingService.geminiEnabledDefaultsKey)
        UserDefaults.standard.set(normalizedOpenAIModel, forKey: AIWritingService.modelDefaultsKey)
        UserDefaults.standard.set(normalizedGeminiModel, forKey: AIWritingService.geminiModelDefaultsKey)

        if !trimmedOpenAIAPIKey.isEmpty {
            guard KeychainHelper.save(
                service: AIWritingService.keychainService,
                account: AIWritingService.apiKeyKeychainAccount,
                value: trimmedOpenAIAPIKey
            ) else {
                aiMessage = "Failed to save OpenAI API key in Keychain."
                return
            }
        }
        if !trimmedGeminiAPIKey.isEmpty {
            guard KeychainHelper.save(
                service: AIWritingService.keychainService,
                account: AIWritingService.geminiAPIKeyKeychainAccount,
                value: trimmedGeminiAPIKey
            ) else {
                aiMessage = "Failed to save Gemini API key in Keychain."
                return
            }
        }

        guard showMessage else { return }
        if !aiEnabled {
            aiMessage = "AI settings saved."
            return
        }
        if !openAIEnabled && !geminiEnabled {
            aiMessage = "Saved. Enable at least one AI provider."
            return
        }
        if aiProvider == .openAI && openAIEnabled && trimmedOpenAIAPIKey.isEmpty {
            aiMessage = "Saved. Add an OpenAI API key before using OpenAI."
            return
        }
        if aiProvider == .gemini && geminiEnabled && trimmedGeminiAPIKey.isEmpty {
            aiMessage = "Saved. Add a Gemini API key before using Gemini."
            return
        }
        aiMessage = "AI settings saved."
    }

    private func saveAISettings() {
        persistAISettings(showMessage: true)
    }

    private func scheduleAIAutosave() {
        aiAutosaveTask?.cancel()
        aiAutosaveTask = Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                persistAISettings(showMessage: false)
            }
        }
    }

    private var trimmedOpenAIAPIKey: String {
        openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedGeminiAPIKey: String {
        geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var modelPickerOptions: [String] {
        var options = availableAIModels
        let trimmedCurrentModel = aiModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCurrentModel.isEmpty && !options.contains(trimmedCurrentModel) {
            options.insert(trimmedCurrentModel, at: 0)
        }
        if options.isEmpty {
            options = [AIWritingService.defaultModel]
        }
        return options
    }

    private var geminiModelPickerOptions: [String] {
        var options = availableGeminiModels
        let trimmedCurrentModel = geminiModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCurrentModel.isEmpty && !options.contains(trimmedCurrentModel) {
            options.insert(trimmedCurrentModel, at: 0)
        }
        if options.isEmpty {
            options = [AIWritingService.defaultGeminiModel]
        }
        return options
    }

    private func fetchAIModels(force: Bool = false) {
        guard !trimmedOpenAIAPIKey.isEmpty else {
            aiModelFetchTask?.cancel()
            availableAIModels = []
            loadedModelsForAPIKey = ""
            isLoadingAIModels = false
            return
        }
        if !force && loadedModelsForAPIKey == trimmedOpenAIAPIKey && !availableAIModels.isEmpty {
            return
        }

        aiModelFetchTask?.cancel()
        let key = trimmedOpenAIAPIKey
        isLoadingAIModels = true

        aiModelFetchTask = Task {
            do {
                let models = try await AIWritingService.shared.listAvailableModels(apiKey: key)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    availableAIModels = models
                    loadedModelsForAPIKey = key
                    isLoadingAIModels = false
                    if aiModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        aiModel = models.first ?? AIWritingService.defaultModel
                    }
                }
            } catch is CancellationError {
                await MainActor.run {
                    isLoadingAIModels = false
                }
            } catch {
                await MainActor.run {
                    isLoadingAIModels = false
                    aiMessage = "Could not load models. You can still type a model manually."
                }
            }
        }
    }

    private func fetchGeminiModels(force: Bool = false) {
        guard !trimmedGeminiAPIKey.isEmpty else {
            geminiModelFetchTask?.cancel()
            availableGeminiModels = []
            loadedModelsForGeminiAPIKey = ""
            isLoadingGeminiModels = false
            return
        }
        if !force && loadedModelsForGeminiAPIKey == trimmedGeminiAPIKey && !availableGeminiModels.isEmpty {
            return
        }

        geminiModelFetchTask?.cancel()
        let key = trimmedGeminiAPIKey
        isLoadingGeminiModels = true

        geminiModelFetchTask = Task {
            do {
                let models = try await AIWritingService.shared.listAvailableGeminiModels(apiKey: key)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    availableGeminiModels = models
                    loadedModelsForGeminiAPIKey = key
                    isLoadingGeminiModels = false
                    if geminiModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        geminiModel = models.first ?? AIWritingService.defaultGeminiModel
                    }
                }
            } catch is CancellationError {
                await MainActor.run {
                    isLoadingGeminiModels = false
                }
            } catch {
                await MainActor.run {
                    isLoadingGeminiModels = false
                    aiMessage = "Could not load Gemini models. You can still type a model manually."
                }
            }
        }
    }

    private func deleteAllUnpinnedNotes() {
        let toDelete = store.notes.filter { !$0.pinned }
        for note in toDelete {
            store.delete(note)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Notsy Preferences")
                    .font(.headline)
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Global Hotkey")
                        .font(.subheadline)
                    Text(currentHotkeyDisplay)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(4)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.5), lineWidth: 1))

                    HStack {
                        Button(isRecordingHotkey ? "Recording... (Press keys)" : "Record Shortcut") {
                            startRecordingHotkey()
                        }
                        .pointingHandCursor()
                        Button("Reset Default") {
                            resetDefaultHotkey()
                        }
                        .pointingHandCursor()
                    }

                    if let hotkeyMessage {
                        Text(hotkeyMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Notion Sync")
                        .font(.subheadline)

                    Toggle("Enable Notion sync", isOn: $notionSyncEnabled)
                        .pointingHandCursor()
                        .onTapGesture {
                            cancelRecordingIfNeeded()
                        }
                        .onChange(of: notionSyncEnabled) { _, isEnabled in
                            persistNotionSettings(showMessage: false)
                            if !isEnabled {
                                store.cancelPendingNotionSync()
                                notionMessage = "Notion sync disabled."
                            }
                        }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Database ID")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", text: $notionDatabaseID)
                            .onTapGesture {
                                cancelRecordingIfNeeded()
                            }
                            .onChange(of: notionDatabaseID) { _, _ in
                                scheduleNotionAutosave()
                            }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Integration Secret")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        SecureField("ntn_... or secret_...", text: $notionIntegrationSecret)
                            .onTapGesture {
                                cancelRecordingIfNeeded()
                            }
                            .onChange(of: notionIntegrationSecret) { _, _ in
                                scheduleNotionAutosave()
                            }
                    }

                    HStack {
                        Button("Save Settings") {
                            saveNotionSettings()
                        }
                        .pointingHandCursor()
                        Button(isTestingNotionConnection ? "Testing..." : "Test Notion Connection") {
                            testNotionConnection()
                        }
                        .pointingHandCursor()
                        .disabled(isTestingNotionConnection)
                        Text("Integration secret is stored in macOS Keychain.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Text("In Notion, share the target database with this integration from the database page's Connections menu.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if let notionMessage {
                        Text(notionMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("AI Writing")
                        .font(.subheadline)

                    Toggle("Enable AI text actions", isOn: $aiEnabled)
                        .pointingHandCursor()
                        .onTapGesture {
                            cancelRecordingIfNeeded()
                        }
                        .onChange(of: aiEnabled) { _, _ in
                            persistAISettings(showMessage: false)
                        }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Preferred provider")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Picker("Preferred provider", selection: $aiProvider) {
                            ForEach(AIWritingProvider.allCases) { provider in
                                Text(provider.label).tag(provider)
                            }
                        }
                        .pickerStyle(.segmented)
                        .pointingHandCursor()
                        .onChange(of: aiProvider) { _, _ in
                            scheduleAIAutosave()
                        }
                    }

                    Toggle("Enable OpenAI", isOn: $openAIEnabled)
                        .pointingHandCursor()
                        .onTapGesture {
                            cancelRecordingIfNeeded()
                        }
                        .onChange(of: openAIEnabled) { _, _ in
                            scheduleAIAutosave()
                        }

                    Toggle("Enable Gemini", isOn: $geminiEnabled)
                        .pointingHandCursor()
                        .onTapGesture {
                            cancelRecordingIfNeeded()
                        }
                        .onChange(of: geminiEnabled) { _, _ in
                            scheduleAIAutosave()
                        }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("OpenAI model")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        if !trimmedOpenAIAPIKey.isEmpty {
                            HStack(spacing: 8) {
                                Picker("Model", selection: $aiModel) {
                                    ForEach(modelPickerOptions, id: \.self) { model in
                                        Text(model).tag(model)
                                    }
                                }
                                .labelsHidden()
                                .onChange(of: aiModel) { _, _ in
                                    scheduleAIAutosave()
                                }

                                Button(isLoadingAIModels ? "Loading..." : "Refresh") {
                                    fetchAIModels(force: true)
                                }
                                .pointingHandCursor()
                                .disabled(isLoadingAIModels)
                            }
                        } else {
                            TextField(AIWritingService.defaultModel, text: $aiModel)
                                .onTapGesture {
                                    cancelRecordingIfNeeded()
                                }
                                .onChange(of: aiModel) { _, _ in
                                    scheduleAIAutosave()
                                }
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("OpenAI API Key")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        SecureField("sk-...", text: $openAIAPIKey)
                            .onTapGesture {
                                cancelRecordingIfNeeded()
                            }
                            .onChange(of: openAIAPIKey) { _, _ in
                                scheduleAIAutosave()
                                fetchAIModels()
                            }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Gemini model")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        if !trimmedGeminiAPIKey.isEmpty {
                            HStack(spacing: 8) {
                                Picker("Gemini model", selection: $geminiModel) {
                                    ForEach(geminiModelPickerOptions, id: \.self) { model in
                                        Text(model).tag(model)
                                    }
                                }
                                .labelsHidden()
                                .onChange(of: geminiModel) { _, _ in
                                    scheduleAIAutosave()
                                }

                                Button(isLoadingGeminiModels ? "Loading..." : "Refresh") {
                                    fetchGeminiModels(force: true)
                                }
                                .pointingHandCursor()
                                .disabled(isLoadingGeminiModels)
                            }
                        } else {
                            TextField(AIWritingService.defaultGeminiModel, text: $geminiModel)
                                .onTapGesture {
                                    cancelRecordingIfNeeded()
                                }
                                .onChange(of: geminiModel) { _, _ in
                                    scheduleAIAutosave()
                                }
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Gemini API Key")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        SecureField("AIza...", text: $geminiAPIKey)
                            .onTapGesture {
                                cancelRecordingIfNeeded()
                            }
                            .onChange(of: geminiAPIKey) { _, _ in
                                scheduleAIAutosave()
                                fetchGeminiModels()
                            }
                    }

                    HStack {
                        Button("Save AI Settings") {
                            saveAISettings()
                        }
                        .pointingHandCursor()
                        Text("API keys are stored in macOS Keychain.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if let aiMessage {
                        Text(aiMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Appearance")
                        .font(.subheadline)

                    Picker("Editor Theme", selection: $themeVariantRaw) {
                        ForEach(NotsyThemeVariant.allCases, id: \.rawValue) { variant in
                            Text(variant.label).tag(variant.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .pointingHandCursor()

                    Picker("Selection Highlight", selection: $selectionColorChoice) {
                        Text("Blue").tag("blue")
                        Text("Gray").tag("gray")
                    }
                    .pickerStyle(.segmented)
                    .pointingHandCursor()
                }

                Divider()
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Data Management")
                        .font(.subheadline)
                    
                    Button(action: {
                        showDeleteUnpinnedConfirmation = true
                    }) {
                        Text("Delete All Unpinned Notes")
                    }
                    .pointingHandCursor()
                    
                    Button(role: .destructive, action: {
                        for note in store.notes {
                            store.delete(note)
                        }
                    }) {
                        Text("Delete Entire Database")
                            .foregroundColor(.red)
                    }
                    .pointingHandCursor()
                }
                
                Divider()
                
                HStack {
                    Spacer()
                    Button("Quit Notsy") {
                        NSApp.terminate(nil)
                    }
                    .pointingHandCursor()
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            fetchAIModels()
            fetchGeminiModels()
        }
        .onDisappear {
            notionAutosaveTask?.cancel()
            aiAutosaveTask?.cancel()
            aiModelFetchTask?.cancel()
            geminiModelFetchTask?.cancel()
            removeKeyMonitor()
        }
        .confirmationDialog(
            "Delete all unpinned notes?",
            isPresented: $showDeleteUnpinnedConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                deleteAllUnpinnedNotes()
            }
            .pointingHandCursor()
            Button("Cancel", role: .cancel) {}
                .pointingHandCursor()
        } message: {
            let count = store.notes.filter { !$0.pinned }.count
            Text("This will permanently delete \(count) unpinned note\(count == 1 ? "" : "s").")
        }
        .frame(width: 480, height: 560)
    }
}
