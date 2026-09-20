import AppKit
import SwiftUI

/// The orange of warning TEXT (notes, "Skipped", "second press" lines). The system orange is fine as a fill or
/// a dot but reads at about 2.2:1 on a light panel, well under the 4.5:1 that small text needs; in the light
/// appearance this is a darker orange, in the dark one the system orange (which is bright enough there).
enum WarningTextColor {
    static let lightAppearance = NSColor(srgbRed: 0.65, green: 0.30, blue: 0, alpha: 1)

    static let nsColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .systemOrange : lightAppearance
    }

    static let color = Color(nsColor: nsColor)
}
