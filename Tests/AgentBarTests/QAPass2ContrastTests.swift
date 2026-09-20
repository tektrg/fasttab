import AppKit
import Testing
@testable import AgentBar

/// QA pass 2: small orange warning text must be readable in light and dark (WCAG AA for small text: 4.5:1).
@MainActor
struct QAPass2ContrastTests {
    private func luminance(_ color: NSColor) -> Double {
        let rgb = color.usingColorSpace(.sRGB)!
        func linear(_ v: CGFloat) -> Double { v <= 0.03928 ? Double(v) / 12.92 : pow((Double(v) + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
    }

    private func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        let (hi, lo) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b)))
        return (hi + 0.05) / (lo + 0.05)
    }

    private func resolved(_ color: NSColor, _ name: NSAppearance.Name) -> NSColor {
        var result = color
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance { result = color.usingColorSpace(.sRGB)! }
        return result
    }

    @Test func theSystemOrangeIsTooFaintForSmallTextOnALightPanel() {
        #expect(contrast(resolved(.systemOrange, .aqua), .white) < 4.5)   // why WarningTextColor exists
    }

    @Test func warningTextIsReadableOnALightPanelAndOnADarkOne() {
        let light = resolved(WarningTextColor.nsColor, .aqua)
        let dark = resolved(WarningTextColor.nsColor, .darkAqua)
        #expect(contrast(light, NSColor(srgbRed: 0.93, green: 0.93, blue: 0.93, alpha: 1)) >= 4.5)   // a grey material at its lightest
        #expect(contrast(dark, NSColor(srgbRed: 0.25, green: 0.25, blue: 0.25, alpha: 1)) >= 4.5)    // and at its lightest in dark
    }
}
