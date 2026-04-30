import SwiftUI

enum NotsyThemeVariant: String, CaseIterable {
    case light
    case bluish
    case pinkish
    case greenish
    case quiet

    var label: String {
        switch self {
        case .light: return "Light"
        case .bluish: return "Midnight"
        case .pinkish: return "Graphite"
        case .greenish: return "Slate"
        case .quiet: return "Quiet"
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
    // Quiet-specific tones (used only by Quiet sidebar/editor accents).
    // Other themes can mirror existing values; downstream code reads these
    // via Theme.q* helpers when isQuiet is true.
    let qAccent: Color
    let qRowTitle: Color
    let qRowTitleActive: Color
    let qSecondary: Color
    let qMuted: Color
    let qFaint: Color
    let qHairline: Color
    let qActiveBg: Color
}

struct Theme {
    static let themeDefaultsKey = "notsy.theme.variant"

    static var variant: NotsyThemeVariant {
        let raw = UserDefaults.standard.string(forKey: themeDefaultsKey) ?? NotsyThemeVariant.bluish.rawValue
        return NotsyThemeVariant(rawValue: raw) ?? .bluish
    }

    static var isQuiet: Bool { variant == .quiet }

    static func palette(for variant: NotsyThemeVariant) -> ThemePalette {
        // Default Quiet tones — overridden in the .quiet case below.
        let defaultQAccent = Color(red: 0.78, green: 0.60, blue: 0.41)
        let defaultQ: (rowTitle: Color, rowTitleActive: Color, secondary: Color, muted: Color, faint: Color, hairline: Color, activeBg: Color) = (
            rowTitle: Color(red: 0.66, green: 0.63, blue: 0.58),
            rowTitleActive: Color(red: 0.96, green: 0.94, blue: 0.89),
            secondary: Color(red: 0.78, green: 0.76, blue: 0.71),
            muted: Color(red: 0.48, green: 0.45, blue: 0.42),
            faint: Color(red: 0.36, green: 0.34, blue: 0.31),
            hairline: Color(red: 0.13, green: 0.12, blue: 0.11),
            activeBg: Color(red: 0.14, green: 0.13, blue: 0.11)
        )

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
                preferredColorScheme: .light,
                qAccent: defaultQAccent,
                qRowTitle: defaultQ.rowTitle,
                qRowTitleActive: defaultQ.rowTitleActive,
                qSecondary: defaultQ.secondary,
                qMuted: defaultQ.muted,
                qFaint: defaultQ.faint,
                qHairline: defaultQ.hairline,
                qActiveBg: defaultQ.activeBg
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
                preferredColorScheme: .dark,
                qAccent: defaultQAccent,
                qRowTitle: defaultQ.rowTitle,
                qRowTitleActive: defaultQ.rowTitleActive,
                qSecondary: defaultQ.secondary,
                qMuted: defaultQ.muted,
                qFaint: defaultQ.faint,
                qHairline: defaultQ.hairline,
                qActiveBg: defaultQ.activeBg
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
                preferredColorScheme: .dark,
                qAccent: defaultQAccent,
                qRowTitle: defaultQ.rowTitle,
                qRowTitleActive: defaultQ.rowTitleActive,
                qSecondary: defaultQ.secondary,
                qMuted: defaultQ.muted,
                qFaint: defaultQ.faint,
                qHairline: defaultQ.hairline,
                qActiveBg: defaultQ.activeBg
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
                preferredColorScheme: .dark,
                qAccent: defaultQAccent,
                qRowTitle: defaultQ.rowTitle,
                qRowTitleActive: defaultQ.rowTitleActive,
                qSecondary: defaultQ.secondary,
                qMuted: defaultQ.muted,
                qFaint: defaultQ.faint,
                qHairline: defaultQ.hairline,
                qActiveBg: defaultQ.activeBg
            )
        case .quiet:
            // --q-bg-app:#1a1816, --q-bg-sidebar:#161412, --q-bg-active:#23201d,
            // --q-border-hair:#221f1c, --q-text-primary:#f5efe4, --q-text-secondary:#c8c1b5,
            // --q-text-tertiary:#a8a194, --q-text-muted:#7a736a, --q-text-faint:#5d574e,
            // --q-accent:#c89968
            let accent = Color(red: 0xc8/255, green: 0x99/255, blue: 0x68/255)
            return ThemePalette(
                bg: Color(red: 0x1a/255, green: 0x18/255, blue: 0x16/255),
                sidebarBg: Color(red: 0x16/255, green: 0x14/255, blue: 0x12/255),
                elementBg: Color(red: 0x23/255, green: 0x20/255, blue: 0x1d/255),
                selection: accent,
                text: Color(red: 0xf5/255, green: 0xef/255, blue: 0xe4/255),
                textMuted: Color(red: 0x5d/255, green: 0x57/255, blue: 0x4e/255),
                border: Color(red: 0x22/255, green: 0x1f/255, blue: 0x1c/255),
                pinGold: accent,
                pinBg: accent.opacity(0.18),
                calloutBg: Color(red: 0x23/255, green: 0x20/255, blue: 0x1d/255),
                editorText: NSColor(red: 0xf5/255, green: 0xef/255, blue: 0xe4/255, alpha: 1),
                preferredColorScheme: .dark,
                qAccent: accent,
                qRowTitle: Color(red: 0xa8/255, green: 0xa1/255, blue: 0x94/255),
                qRowTitleActive: Color(red: 0xf5/255, green: 0xef/255, blue: 0xe4/255),
                qSecondary: Color(red: 0xc8/255, green: 0xc1/255, blue: 0xb5/255),
                qMuted: Color(red: 0x7a/255, green: 0x73/255, blue: 0x6a/255),
                qFaint: Color(red: 0x5d/255, green: 0x57/255, blue: 0x4e/255),
                qHairline: Color(red: 0x22/255, green: 0x1f/255, blue: 0x1c/255),
                qActiveBg: Color(red: 0x23/255, green: 0x20/255, blue: 0x1d/255)
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

    static var qAccent: Color { current.qAccent }
    static var qRowTitle: Color { current.qRowTitle }
    static var qRowTitleActive: Color { current.qRowTitleActive }
    static var qSecondary: Color { current.qSecondary }
    static var qMuted: Color { current.qMuted }
    static var qFaint: Color { current.qFaint }
    static var qHairline: Color { current.qHairline }
    static var qActiveBg: Color { current.qActiveBg }
}
