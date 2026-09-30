import AppKit
import CommandBarKit
import IndieMotion

// Which picture each Mac onboarding hero shows, from its step's live state,
// and how its clock runs. Pure, so the mapping is unit-tested without
// rendering. Timings follow the approved storyboard
// (`onboarding-motion.html`, "Mac onboarding" cards 1–7).

/// Step 1: the core loop (open the bar, type, land on a tab). No live state.
enum WelcomeHero {
    static let playback = MotionPlayback.loop(period: 3.0, restAt: 2.6)
}

/// Step 2: where the hover trigger lives. Follows the step's radio choice live.
enum TriggerHeroState: Hashable {
    /// Pointer glides to the hot spot, a pill peeks, the bar slides out of it.
    case hover(EdgeRevealStyle)
    /// Hovering is off: the user's shortcut keys press and the bar pops.
    case keyboard(keycaps: [String])

    init(style: EdgeRevealStyle, shortcutKeycaps: [String]) {
        self = style == .off ? .keyboard(keycaps: shortcutKeycaps) : .hover(style)
    }

    var playback: MotionPlayback {
        switch self {
        case .hover: return .loop(period: 3.0, restAt: 2.6)
        case .keyboard: return ShortcutHeroKeycaps.playback
        }
    }
}

/// Step 3: enabled apps stream tabs into one search field; disabled ones dim.
struct SourcesHeroState: Hashable {
    /// Enabled sources in the picker's order (`SearchSource.allCases`).
    let enabledSources: [SearchSource]

    init(enabled: Set<SearchSource>) {
        enabledSources = SearchSource.allCases.filter(enabled.contains)
    }

    func isEnabled(_ source: SearchSource) -> Bool { enabledSources.contains(source) }

    var playback: MotionPlayback { .loop(period: 2.8, restAt: 2.3) }
}

/// Step 4: Recents is a guess until the extension's piece snaps in.
enum ExtensionHeroState: Hashable {
    /// Not usable yet (waiting, turned off, or wrong version): the piece bobs
    /// beside its socket, the list stays in guessed order.
    case teaching
    /// Usable: the piece snaps in, a check bounces, rows fall into true order
    /// and the playing tab rises to the top. Plays once.
    case connected

    init(setupState: ExtensionSetupState) {
        self = setupState == .usable ? .connected : .teaching
    }

    var playback: MotionPlayback {
        switch self {
        case .teaching: return .loop(period: 3.0, restAt: 0.5)
        case .connected: return .once(duration: 1.2)
        }
    }

    /// The step moves on by itself once connected. It waits for the success
    /// beat to finish and holds it briefly, so the user sees what changed.
    static var autoAdvanceDelay: Duration {
        .milliseconds(Int((connected.playback.restTime + 0.4) * 1000))
    }
}

/// Step 5: drag the app into System Settings › Full Disk Access.
enum SafariHeroState: Hashable {
    /// A ghost of the app icon drags into the empty row; toggle and lock open.
    case teaching
    /// Access is on: toggle flips, lock opens, a check bounces. Plays once.
    case granted

    init(isGranted: Bool) {
        self = isGranted ? .granted : .teaching
    }

    var playback: MotionPlayback {
        switch self {
        // Rests with the ghost parked over the empty row, ready to drop.
        case .teaching: return .loop(period: 3.2, restAt: 1.2)
        case .granted: return .once(duration: 1.4)
        }
    }
}

/// Step 6: a tab travels Mac → iCloud → iPhone and a link flies back.
enum IPhoneHeroState: Hashable {
    case teaching
    /// An iPhone has checked in over sync: a link line draws, a check bounces.
    case connected

    init(isPhoneConnected: Bool) {
        self = isPhoneConnected ? .connected : .teaching
    }

    var playback: MotionPlayback {
        switch self {
        case .teaching: return .loop(period: 3.2, restAt: 2.8)
        case .connected: return .once(duration: 1.3)
        }
    }
}

/// Step 7 (and step 2 with hovering off): the user's own shortcut, one
/// keycap per modifier plus the key.
enum ShortcutHeroKeycaps {
    static func keycaps(modifiers: NSEvent.ModifierFlags, keyName: String) -> [String] {
        let modifierCaps = ViewShortcut.modifierSymbols(for: modifiers).map(String.init)
        return keyName.isEmpty ? modifierCaps : modifierCaps + [keyName]
    }

    /// When the bar pops: after the last key goes down.
    static func barPopTime(keyCount: Int) -> Double {
        firstPressTime + Double(keyCount) * pressStagger
    }

    /// When every key is back up.
    static func releaseEndTime(keyCount: Int) -> Double {
        barPopTime(keyCount: keyCount) + releaseDelay + releaseDuration
    }

    static let firstPressTime = 0.3
    static let pressStagger = 0.16
    /// Keys stay down this long after the bar pops, then lift over `releaseDuration`.
    static let releaseDelay = 0.9
    static let releaseDuration = 0.15
    static let playback = MotionPlayback.loop(period: 2.8, restAt: 2.3)
}

extension ShortcutStore {
    /// The main shortcut as hero keycaps, e.g. `["⌥", "Space"]`.
    var heroKeycaps: [String] {
        ShortcutHeroKeycaps.keycaps(modifiers: modifiers, keyName: keyDisplayName)
    }
}
