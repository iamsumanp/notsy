import SwiftUI

enum NotsyThemeVariant: String, CaseIterable {
    case light
    case bluish
    case pinkish
    case greenish

    var label: String {
        switch self {
        case .light: return "Light"
        case .bluish: return "Midnight"
        case .pinkish: return "Graphite"
        case .greenish: return "Slate"
        }
    }
}

struct ThemePalette {
    let bg: Color
    let sidebarBg: Color
    let elementBg: Color
    let selection: Color
    let text: Color
    let textMuted: Color
    let border: Color
    let pinGold: Color
    let pinBg: Color
    let calloutBg: Color
    let editorText: NSColor
    let preferredColorScheme: ColorScheme
}

struct Theme {
    static let themeDefaultsKey = "notsy.theme.variant"

    static var variant: NotsyThemeVariant {
        let raw = UserDefaults.standard.string(forKey: themeDefaultsKey) ?? NotsyThemeVariant.bluish.rawValue
        return NotsyThemeVariant(rawValue: raw) ?? .bluish
    }

    static func palette(for variant: NotsyThemeVariant) -> ThemePalette {
        switch variant {
        case .light:
            return ThemePalette(
                bg: Color(red: 0.95, green: 0.95, blue: 0.96),
                sidebarBg: Color(red: 0.92, green: 0.93, blue: 0.95),
                elementBg: Color(red: 0.86, green: 0.88, blue: 0.91),
                selection: Color(red: 0.60, green: 0.68, blue: 0.90),
                text: Color(red: 0.12, green: 0.13, blue: 0.15),
                textMuted: Color(red: 0.40, green: 0.43, blue: 0.48),
                border: Color(red: 0.78, green: 0.80, blue: 0.84),
                pinGold: Color.green,
                pinBg: Color.green.opacity(0.2),
                calloutBg: Color(red: 0.86, green: 0.90, blue: 0.98),
                editorText: NSColor(red: 0.12, green: 0.13, blue: 0.15, alpha: 1),
                preferredColorScheme: .light
            )
        case .bluish:
            return ThemePalette(
                bg: Color(red: 0.10, green: 0.10, blue: 0.11),
                sidebarBg: Color(red: 0.12, green: 0.12, blue: 0.13),
                elementBg: Color(red: 0.16, green: 0.16, blue: 0.18),
                selection: Color(red: 0.35, green: 0.55, blue: 0.98),
                text: Color(red: 0.95, green: 0.95, blue: 0.95),
                textMuted: Color(red: 0.60, green: 0.60, blue: 0.62),
                border: Color(red: 0.20, green: 0.20, blue: 0.22),
                pinGold: Color.green,
                pinBg: Color.green.opacity(0.2),
                calloutBg: Color(red: 0.15, green: 0.18, blue: 0.28),
                editorText: NSColor.white,
                preferredColorScheme: .dark
            )
        case .pinkish:
            return ThemePalette(
                bg: Color(red: 0.11, green: 0.12, blue: 0.14),
                sidebarBg: Color(red: 0.13, green: 0.14, blue: 0.16),
                elementBg: Color(red: 0.17, green: 0.18, blue: 0.21),
                selection: Color(red: 0.45, green: 0.58, blue: 0.77),
                text: Color(red: 0.93, green: 0.94, blue: 0.96),
                textMuted: Color(red: 0.61, green: 0.64, blue: 0.69),
                border: Color(red: 0.22, green: 0.24, blue: 0.28),
                pinGold: Color.green,
                pinBg: Color.green.opacity(0.2),
                calloutBg: Color(red: 0.16, green: 0.19, blue: 0.26),
                editorText: NSColor.white,
                preferredColorScheme: .dark
            )
        case .greenish:
            return ThemePalette(
                bg: Color(red: 0.10, green: 0.11, blue: 0.12),
                sidebarBg: Color(red: 0.12, green: 0.13, blue: 0.14),
                elementBg: Color(red: 0.16, green: 0.17, blue: 0.18),
                selection: Color(red: 0.40, green: 0.55, blue: 0.66),
                text: Color(red: 0.92, green: 0.94, blue: 0.95),
                textMuted: Color(red: 0.60, green: 0.65, blue: 0.68),
                border: Color(red: 0.22, green: 0.24, blue: 0.26),
                pinGold: Color.green,
                pinBg: Color.green.opacity(0.2),
                calloutBg: Color(red: 0.15, green: 0.18, blue: 0.20),
                editorText: NSColor.white,
                preferredColorScheme: .dark
            )
        }
    }

    static var current: ThemePalette {
        palette(for: variant)
    }

    static var bg: Color { current.bg }
    static var sidebarBg: Color { current.sidebarBg }
    static var elementBg: Color { current.elementBg }
    static var selection: Color { current.selection }
    static var text: Color { current.text }
    static var textMuted: Color { current.textMuted }
    static var border: Color { current.border }
    static var pinGold: Color { current.pinGold }
    static var pinBg: Color { current.pinBg }
    static var calloutBg: Color { current.calloutBg }
    static var editorTextNSColor: NSColor { current.editorText }
    static var preferredColorScheme: ColorScheme { current.preferredColorScheme }
}
