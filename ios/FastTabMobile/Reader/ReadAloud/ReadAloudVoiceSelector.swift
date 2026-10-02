import Foundation

/// Engine-neutral description of an installed voice, so selection is testable
/// without `AVSpeechSynthesisVoice` (whose list is device-dependent).
struct ReadAloudVoiceOption: Equatable, Identifiable, Sendable {
    enum Quality: Int, Comparable, Sendable {
        case standard = 0, enhanced, premium
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

        var label: String? {
            switch self {
            case .standard: return nil
            case .enhanced: return "Enhanced"
            case .premium: return "Premium"
            }
        }
    }

    let id: String           // engine voice identifier
    let name: String
    let languageCode: String // BCP-47, e.g. "en-US"
    let quality: Quality

    var primaryLanguage: String { Self.primaryLanguage(of: languageCode) }

    static func primaryLanguage(of code: String) -> String {
        let first = code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? code
        return first.lowercased()
    }
}

enum ReadAloudVoiceSelector {
    /// Voices that can read `languageCode`, best first: premium > enhanced > standard,
    /// then the device's own region, then name.
    static func voices(
        for languageCode: String,
        among available: [ReadAloudVoiceOption],
        preferredRegion: String? = Locale.current.region?.identifier
    ) -> [ReadAloudVoiceOption] {
        let primary = ReadAloudVoiceOption.primaryLanguage(of: languageCode)
        func matchesRegion(_ voice: ReadAloudVoiceOption) -> Bool {
            guard let preferredRegion else { return false }
            return voice.languageCode.uppercased().hasSuffix("-" + preferredRegion.uppercased())
        }
        return available
            .filter { $0.primaryLanguage == primary }
            .sorted { lhs, rhs in
                if lhs.quality != rhs.quality { return lhs.quality > rhs.quality }
                if matchesRegion(lhs) != matchesRegion(rhs) { return matchesRegion(lhs) }
                return lhs.name < rhs.name
            }
    }

    /// The user's saved voice when it speaks the article's language; otherwise the
    /// best installed voice for that language. Nil = let the engine use its default.
    static func select(
        preferredIdentifier: String?,
        languageCode: String?,
        among available: [ReadAloudVoiceOption],
        preferredRegion: String? = Locale.current.region?.identifier
    ) -> ReadAloudVoiceOption? {
        let preferred = available.first { $0.id == preferredIdentifier }
        guard let languageCode else { return preferred }
        if let preferred, preferred.primaryLanguage == ReadAloudVoiceOption.primaryLanguage(of: languageCode) {
            return preferred
        }
        return voices(for: languageCode, among: available, preferredRegion: preferredRegion).first
    }
}
