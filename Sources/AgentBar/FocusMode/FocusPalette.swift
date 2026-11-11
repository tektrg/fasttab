import AppKit
import SwiftUI

/// Focus mode colours, from the mockup (`memory/Projects/agentbar-focus-mode/mockup.html`), light + dark.
enum FocusPalette {
    static let card = dynamic(light: 0xFBFBFA, dark: 0x1B1C20)
    static let panel = dynamic(light: 0xF2F2EF, dark: 0x222328)
    static let ink = dynamic(light: 0x1D1F23, dark: 0xECEBE8)
    static let mute = dynamic(light: 0x6B6F78, dark: 0x9A9CA3)
    static let line = dynamic(light: 0xE3E3DF, dark: 0x2E3036)
    static let selected = dynamic(light: 0xFFFFFF, dark: 0x2B2C33)
    static let accent = Color(nsColor: NSColor(srgbRed: 0xD6 / 255, green: 0x45 / 255, blue: 0x3D / 255, alpha: 1))
    static let ok = Color(nsColor: NSColor(srgbRed: 0x2F / 255, green: 0x9E / 255, blue: 0x6A / 255, alpha: 1))
    /// The dim over the rest of the screen: black 45% light / 60% dark.
    static let dimOpacityLight = 0.45
    static let dimOpacityDark = 0.60

    private static func dynamic(light: Int, dark: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1
            )
        })
    }
}
