import SwiftUI

struct Theme {
    static let bg = Color(red: 0.10, green: 0.10, blue: 0.11) // Very dark gray/black background
    static let sidebarBg = Color(red: 0.12, green: 0.12, blue: 0.13)
    static let elementBg = Color(red: 0.16, green: 0.16, blue: 0.18)
    static let selection = Color(red: 0.35, green: 0.55, blue: 0.98) // Light vivid blue
    static let text = Color(red: 0.95, green: 0.95, blue: 0.95)
    static let textMuted = Color(red: 0.60, green: 0.60, blue: 0.62)
    static let border = Color(red: 0.20, green: 0.20, blue: 0.22)
    static let pinGold = Color.green // Replaced with green active indicator
    static let pinBg = Color.green.opacity(0.2)
    static let calloutBg = Color(red: 0.15, green: 0.18, blue: 0.28) // Deep blue for callouts
}
