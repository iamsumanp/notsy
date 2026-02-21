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

        if notionSyncEnabled {
            notionMessage = (trimmedDatabaseID.isEmpty || trimmedIntegrationSecret.isEmpty)
                ? "Saved. Add Database ID and Integration Secret before sync can run."
                : "Notion sync settings saved."
        } else {
            notionMessage = "Notion settings saved."
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
                        Text("Integration Secret")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        SecureField("ntn_... or secret_...", text: $notionIntegrationSecret)
                    }

                    HStack {
                        Button("Save Settings") {
                            saveNotionSettings()
                        }
                        Button(isTestingNotionConnection ? "Testing..." : "Test Notion Connection") {
                            testNotionConnection()
                        }
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
                    Text("Appearance")
                        .font(.subheadline)

                    Picker("Editor Theme", selection: $themeVariantRaw) {
                        ForEach(NotsyThemeVariant.allCases, id: \.rawValue) { variant in
                            Text(variant.label).tag(variant.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)

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
        }
        .frame(width: 480, height: 560)
    }
}
