import Foundation

/// The four voices of Paradee-8M v1.2 (on-device English voice). Raw values are the model's
/// voice names; the model's own numbering comes from `paradee_config.json` at load time.
enum ParadeeVoice: String, CaseIterable, Sendable {
    case heart = "af_heart"
    case puck = "am_puck"
    case isabella = "bf_isabella"
    case fable = "bm_fable"

    static let `default` = ParadeeVoice.heart

    var name: String {
        switch self {
        case .heart: return "Heart"
        case .puck: return "Puck"
        case .isabella: return "Isabella"
        case .fable: return "Fable"
        }
    }

    /// The British voices were trained on British phonemes, the American ones on American.
    var accent: ParadeeAccent { rawValue.hasPrefix("b") ? .british : .american }

    var accentLabel: String { accent == .british ? "British" : "American" }

    /// Saved choice (`ReaderReadingSettings.paradeeVoiceID`); nil or unknown → Heart.
    static func resolve(_ saved: String?) -> ParadeeVoice {
        saved.flatMap(ParadeeVoice.init(rawValue:)) ?? .default
    }

    // MARK: - As a Read Aloud voice option

    /// Prefix that keeps Paradee voice ids apart from `AVSpeechSynthesisVoice` identifiers.
    static let optionPrefix = "paradee."

    var optionID: String { Self.optionPrefix + rawValue }

    init?(optionID: String?) {
        guard let optionID, optionID.hasPrefix(Self.optionPrefix) else { return nil }
        self.init(rawValue: String(optionID.dropFirst(Self.optionPrefix.count)))
    }

    var option: ReadAloudVoiceOption {
        ReadAloudVoiceOption(id: optionID, name: name, languageCode: accent == .british ? "en-GB" : "en-US",
                             quality: .premium)
    }

    // MARK: - Speed

    /// The model's `speed` input (1 = normal) for Read Aloud's speed multiplier. Outside
    /// 0.5–2 the voice garbles, so the multiplier is clamped there.
    static func speed(forRate rate: Double) -> Float {
        Float(min(max(rate, 0.5), 2.0))
    }
}

/// When English articles are read by Paradee instead of the device / natural voice.
enum ParadeeGate {
    /// The "English voice (beta)" switch exists only in DEBUG and TestFlight builds for now.
    static var isOfferedInThisBuild: Bool { AppDistribution.isDebugOrTestFlight }

    /// The switch: on by default wherever it is offered; never on in an App Store build.
    static func isEnabled(setting: Bool?, offered: Bool) -> Bool {
        offered && (setting ?? true)
    }

    /// English articles go to Paradee when it is on; every other language is untouched.
    static func routesToParadee(languageCode: String?, setting: Bool?, offered: Bool) -> Bool {
        guard isEnabled(setting: setting, offered: offered), let languageCode else { return false }
        return ReadAloudVoiceOption.primaryLanguage(of: languageCode) == "en"
    }
}
