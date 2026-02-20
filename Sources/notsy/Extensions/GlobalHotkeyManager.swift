import Carbon
import Cocoa

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
    private var hotKeyRef: EventHotKeyRef?

    private init() {
        setupHotKey()
    }

    private func setupHotKey() {
        // ----------------------------------------------------------------------
        // 🔧 WHERE TO MODIFY HOTKEY
        // ----------------------------------------------------------------------
        // Default: Command + Shift + Space
        //
        // Common KeyCodes:
        // Space = 49, Return = 36, Esc = 53, N = 45
        //
        // Common Modifiers:
        // cmdKey, shiftKey, optionKey, controlKey
        // Combine them with bitwise OR (|)
        // ----------------------------------------------------------------------
        let keyCode: UInt32 = 49  // Space
        let modifiers: UInt32 = UInt32(cmdKey | shiftKey)

        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType(fourCharCode("NTBR"))
        hotKeyID.id = 1

        var eventType = EventTypeSpec()
        eventType.eventClass = OSType(kEventClassKeyboard)
        eventType.eventKind = OSType(kEventHotKeyPressed)

        InstallEventHandler(GetApplicationEventTarget(), hotKeyHandler, 1, &eventType, nil, nil)

        RegisterEventHotKey(
            keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    private func fourCharCode(_ string: String) -> UInt32 {
        var result: UInt32 = 0
        for char in string.utf8 {
            result = (result << 8) + UInt32(char)
        }
        return result
    }
}
