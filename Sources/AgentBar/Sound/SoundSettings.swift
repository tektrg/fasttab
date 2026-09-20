import Foundation

/// What can be picked for an alert: one of the macOS system sounds (`/System/Library/Sounds`), or nothing.
/// The raw value is the sound's file name, and what is stored in the defaults.
enum SoundChoice: String, CaseIterable, Sendable {
    case none = "None"
    case basso = "Basso", blow = "Blow", bottle = "Bottle", frog = "Frog", funk = "Funk", glass = "Glass"
    case hero = "Hero", morse = "Morse", ping = "Ping", pop = "Pop", purr = "Purr", sosumi = "Sosumi"
    case submarine = "Submarine", tink = "Tink"

    /// The name `NSSound(named:)` knows it by; nil for "None".
    var systemSoundName: String? { self == .none ? nil : rawValue }
}

/// The two alerts an agent arriving in Needs you can make (see `ArrivalSoundPlanner`).
enum SoundCue: Equatable, Sendable {
    /// Blocked on the user: a question to answer or a permission box to review.
    case needsAnswer
    /// Simply finished or idle.
    case agentDone
}

/// Whether AgentBar plays alerts, and which sound each cue uses. Persisted in the app's defaults.
struct SoundSettings: Equatable, Sendable {
    static let playsSoundsKey = "playsSounds"
    static let needsAnswerKey = "needsAnswerSound"
    static let agentDoneKey = "agentDoneSound"

    var playsSounds = true
    var needsAnswer: SoundChoice = .funk
    var agentDone: SoundChoice = .glass

    static let standard = SoundSettings()

    /// The sound for a cue.
    func choice(for cue: SoundCue) -> SoundChoice {
        switch cue {
        case .needsAnswer: needsAnswer
        case .agentDone: agentDone
        }
    }

    /// Reads the saved values; anything missing or not a known sound name falls back to its default.
    static func load(from defaults: UserDefaults) -> SoundSettings {
        func stored(_ key: String, fallback: SoundChoice) -> SoundChoice {
            (defaults.string(forKey: key)).flatMap(SoundChoice.init(rawValue:)) ?? fallback
        }
        return SoundSettings(
            playsSounds: defaults.object(forKey: playsSoundsKey) as? Bool ?? standard.playsSounds,
            needsAnswer: stored(needsAnswerKey, fallback: standard.needsAnswer),
            agentDone: stored(agentDoneKey, fallback: standard.agentDone)
        )
    }

    func save(to defaults: UserDefaults) {
        defaults.set(playsSounds, forKey: Self.playsSoundsKey)
        defaults.set(needsAnswer.rawValue, forKey: Self.needsAnswerKey)
        defaults.set(agentDone.rawValue, forKey: Self.agentDoneKey)
    }
}
