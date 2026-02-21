import Carbon
import Cocoa

struct HotkeyShortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32

    static let `default` = HotkeyShortcut(
        keyCode: 49,  // Space
        modifiers: UInt32(cmdKey | shiftKey)
    )
}

// C-compatible function for Carbon Event Handler
private func hotKeyHandler(
    nextHandler: EventHandlerCallRef?, theEvent: EventRef?, userData: UnsafeMutableRawPointer?
) -> OSStatus {
    GlobalHotkeyManager.shared.action?()
    return noErr
}

class GlobalHotkeyManager {
    static let shared = GlobalHotkeyManager()

    var action: (() -> Void)?

    private(set) var currentShortcut: HotkeyShortcut
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerInstalled = false
    private let defaultsKey = "NotsyGlobalHotkey"

    private init() {
        currentShortcut = Self.loadShortcutFromDefaults() ?? .default
        setupHotKey()
    }

    private func setupHotKey() {
        installEventHandlerIfNeeded()
        _ = registerHotKey(currentShortcut)
    }

    @discardableResult
    func updateShortcut(keyCode: UInt32, modifiers: UInt32) -> Bool {
        let newShortcut = HotkeyShortcut(keyCode: keyCode, modifiers: modifiers)
        guard newShortcut != currentShortcut else { return true }

        let oldShortcut = currentShortcut
        unregisterCurrentHotKey()
        if registerHotKey(newShortcut) {
            currentShortcut = newShortcut
            saveShortcutToDefaults(newShortcut)
            return true
        }

        _ = registerHotKey(oldShortcut)
        return false
    }

    private func installEventHandlerIfNeeded() {
        guard !eventHandlerInstalled else { return }
        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType(fourCharCode("NTBR"))
        hotKeyID.id = 1

        var eventType = EventTypeSpec()
        eventType.eventClass = OSType(kEventClassKeyboard)
        eventType.eventKind = OSType(kEventHotKeyPressed)

        InstallEventHandler(GetApplicationEventTarget(), hotKeyHandler, 1, &eventType, nil, nil)
        eventHandlerInstalled = true
    }

    @discardableResult
    private func registerHotKey(_ shortcut: HotkeyShortcut) -> Bool {
        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType(fourCharCode("NTBR"))
        hotKeyID.id = 1

        var registeredRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &registeredRef
        )
        guard status == noErr else { return false }
        hotKeyRef = registeredRef
        return true
    }

    private func unregisterCurrentHotKey() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    private static func loadShortcutFromDefaults() -> HotkeyShortcut? {
        guard let data = UserDefaults.standard.data(forKey: "NotsyGlobalHotkey"),
              let shortcut = try? JSONDecoder().decode(HotkeyShortcut.self, from: data) else {
            return nil
        }
        return shortcut
    }

    private func saveShortcutToDefaults(_ shortcut: HotkeyShortcut) {
        guard let data = try? JSONEncoder().encode(shortcut) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    private func fourCharCode(_ string: String) -> UInt32 {
        var result: UInt32 = 0
        for char in string.utf8 {
            result = (result << 8) + UInt32(char)
        }
        return result
    }
}
