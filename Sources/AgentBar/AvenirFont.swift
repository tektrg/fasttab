import SwiftUI

extension Font {
    /// AgentBar's text face: Avenir Next, or the system font when Settings > General > Appearance says so
    /// (`AgentBarSettings.usesAvenirFontKey`), times the text-size scale (`fontScaleKey`). Both are
    /// read from UserDefaults at render time. Code/ids use `avenirMono`, which scales the same way.
    static func avenir(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let usesAvenir = UserDefaults.standard.object(forKey: AgentBarSettings.usesAvenirFontKey) as? Bool ?? true
        let scaled = size * AgentBarSettings.currentFontScale()
        return usesAvenir
            ? .custom("Avenir Next", fixedSize: scaled).weight(weight)
            : .system(size: scaled, weight: weight)
    }

    static func avenirMono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size * AgentBarSettings.currentFontScale(), weight: weight, design: .monospaced)
    }
}
