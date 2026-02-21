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
    @State private var notionClientID: String
    @State private var notionClientSecret: String
    @State private var notionRedirectURI: String
    @State private var notionAuthCode: String
    @State private var notionOAuthState: String
    @State private var notionMessage: String?
    @State private var isAwaitingOAuthCallback = false
    @AppStorage("notsy.selection.color") private var selectionColorChoice: String = "blue"

    init() {
        let shortcut = GlobalHotkeyManager.shared.currentShortcut
        let defaults = UserDefaults.standard
        _keyCode = State(initialValue: shortcut.keyCode)
        _modifiers = State(initialValue: shortcut.modifiers)
        _notionSyncEnabled = State(initialValue: defaults.bool(forKey: NotionSyncService.enabledDefaultsKey))
        _notionDatabaseID = State(initialValue: defaults.string(forKey: NotionSyncService.databaseIDDefaultsKey) ?? "")
        _notionClientID = State(initialValue: defaults.string(forKey: NotionSyncService.oauthClientIDDefaultsKey) ?? "")
        _notionClientSecret = State(initialValue: KeychainHelper.load(
            service: NotionSyncService.keychainService,
            account: NotionSyncService.oauthClientSecretKeychainAccount
        ) ?? "")
        _notionRedirectURI = State(initialValue: defaults.string(forKey: NotionSyncService.oauthRedirectURIDefaultsKey) ?? "")
        _notionAuthCode = State(initialValue: "")
        _notionOAuthState = State(initialValue: UUID().uuidString)
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

    private func saveNotionSettings() {
        let trimmedDatabaseID = notionDatabaseID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedClientID = notionClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedClientSecret = notionClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRedirectURI = notionRedirectURI.trimmingCharacters(in: .whitespacesAndNewlines)

        UserDefaults.standard.set(notionSyncEnabled, forKey: NotionSyncService.enabledDefaultsKey)
        UserDefaults.standard.set(trimmedDatabaseID, forKey: NotionSyncService.databaseIDDefaultsKey)
        UserDefaults.standard.set(trimmedClientID, forKey: NotionSyncService.oauthClientIDDefaultsKey)
        UserDefaults.standard.set(trimmedRedirectURI, forKey: NotionSyncService.oauthRedirectURIDefaultsKey)

        if !trimmedClientSecret.isEmpty {
            guard KeychainHelper.save(
                service: NotionSyncService.keychainService,
                account: NotionSyncService.oauthClientSecretKeychainAccount,
                value: trimmedClientSecret
            ) else {
                notionMessage = "Failed to save OAuth client secret in Keychain."
                return
            }
        }

        if notionSyncEnabled {
            notionMessage = (trimmedDatabaseID.isEmpty || trimmedClientID.isEmpty || trimmedRedirectURI.isEmpty)
                ? "Saved. Configure OAuth and exchange a code before sync can run."
                : "OAuth settings saved. Complete Connect + Exchange Code."
        } else {
            notionMessage = "Notion settings saved."
        }
    }

    private func openNotionOAuth() {
        let trimmedClientID = notionClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRedirectURI = notionRedirectURI.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedClientID.isEmpty, !trimmedRedirectURI.isEmpty else {
            notionMessage = "Add OAuth Client ID and Redirect URI first."
            return
        }

        notionOAuthState = UUID().uuidString
        Task {
            let url = await NotionSyncService.shared.buildOAuthAuthorizationURL(
                clientID: trimmedClientID,
                redirectURI: trimmedRedirectURI,
                state: notionOAuthState
            )
            await MainActor.run {
                guard let url else {
                    notionMessage = "Failed to build OAuth URL."
                    return
                }
                NSWorkspace.shared.open(url)
                notionMessage = "Browser opened. Approve access, then paste the returned code below."
            }
        }
    }

    private func exchangeNotionCode() {
        let trimmedClientID = notionClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedClientSecret = notionClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRedirectURI = notionRedirectURI.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCode = notionAuthCode.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedClientID.isEmpty, !trimmedClientSecret.isEmpty, !trimmedRedirectURI.isEmpty, !trimmedCode.isEmpty else {
            notionMessage = "Fill Client ID, Client Secret, Redirect URI, and Authorization Code."
            return
        }

        notionMessage = "Exchanging code for access token..."
        Task {
            do {
                try await NotionSyncService.shared.exchangeOAuthCode(
                    clientID: trimmedClientID,
                    clientSecret: trimmedClientSecret,
                    redirectURI: trimmedRedirectURI,
                    code: trimmedCode
                )
                await MainActor.run {
                    notionAuthCode = ""
                    notionMessage = "OAuth connected. Notes can now sync to Notion."
                }
            } catch {
                await MainActor.run {
                    notionMessage = "OAuth exchange failed: \(error)"
                }
            }
        }
    }

    private func connectNotionWithLocalhostCallback() {
        let trimmedClientID = notionClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedClientSecret = notionClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        let callbackURI = "http://127.0.0.1:53682/notion/oauth/callback"

        guard !trimmedClientID.isEmpty, !trimmedClientSecret.isEmpty else {
            notionMessage = "Fill OAuth Client ID and Client Secret first."
            return
        }

        notionRedirectURI = callbackURI
        saveNotionSettings()
        notionOAuthState = UUID().uuidString
        isAwaitingOAuthCallback = true
        notionMessage = "Opening browser and waiting for Notion callback..."

        Task {
            do {
                let state = notionOAuthState
                guard let authURL = await NotionSyncService.shared.buildOAuthAuthorizationURL(
                    clientID: trimmedClientID,
                    redirectURI: callbackURI,
                    state: state
                ) else {
                    await MainActor.run {
                        notionMessage = "Failed to build OAuth URL."
                        isAwaitingOAuthCallback = false
                    }
                    return
                }

                async let callback = LocalOAuthCallbackServer.shared.waitForCode(
                    port: 53682,
                    expectedPath: "/notion/oauth/callback"
                )

                await MainActor.run {
                    _ = NSWorkspace.shared.open(authURL)
                }

                let result = try await callback
                if let callbackState = result.state, callbackState != state {
                    throw LocalOAuthCallbackError.stateMismatch
                }

                try await NotionSyncService.shared.exchangeOAuthCode(
                    clientID: trimmedClientID,
                    clientSecret: trimmedClientSecret,
                    redirectURI: callbackURI,
                    code: result.code
                )

                await MainActor.run {
                    notionAuthCode = ""
                    notionMessage = "OAuth connected via localhost callback."
                    isAwaitingOAuthCallback = false
                }
            } catch {
                await MainActor.run {
                    notionMessage = "Auto OAuth failed: \(error)"
                    isAwaitingOAuthCallback = false
                }
            }
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
                        Button("Reset Default") {
                            resetDefaultHotkey()
                        }
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

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Database ID")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", text: $notionDatabaseID)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("OAuth Client ID")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("30dd....", text: $notionClientID)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("OAuth Client Secret")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        SecureField("secret_xxx...", text: $notionClientSecret)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("OAuth Redirect URI")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("https://yourapp.example/callback", text: $notionRedirectURI)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Authorization Code")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("Paste code=... value from redirect URL", text: $notionAuthCode)
                    }

                    HStack {
                        Button("Save Settings") {
                            saveNotionSettings()
                        }
                        Button(isAwaitingOAuthCallback ? "Waiting for callback..." : "Connect (Auto Callback)") {
                            connectNotionWithLocalhostCallback()
                        }
                        .disabled(isAwaitingOAuthCallback)
                        Button("Connect in Browser") {
                            openNotionOAuth()
                        }
                        Button("Exchange Code") {
                            exchangeNotionCode()
                        }
                        Text("Client secret/token stored in macOS Keychain.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if let notionMessage {
                        Text(notionMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Appearance")
                        .font(.subheadline)

                    Picker("Selection Highlight", selection: $selectionColorChoice) {
                        Text("Blue").tag("blue")
                        Text("Gray").tag("gray")
                    }
                    .pickerStyle(.segmented)
                }

                Divider()
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Data Management")
                        .font(.subheadline)
                    
                    Button(action: {
                        let toDelete = store.notes.filter { !$0.pinned }
                        for note in toDelete {
                            store.delete(note)
                        }
                    }) {
                        Text("Delete All Unpinned Notes")
                    }
                    
                    Button(role: .destructive, action: {
                        for note in store.notes {
                            store.delete(note)
                        }
                    }) {
                        Text("Delete Entire Database")
                            .foregroundColor(.red)
                    }
                }
                
                Divider()
                
                HStack {
                    Spacer()
                    Button("Quit Notsy") {
                        NSApp.terminate(nil)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onDisappear {
            removeKeyMonitor()
            LocalOAuthCallbackServer.shared.stop()
        }
        .frame(width: 480, height: 560)
    }
}
