import Foundation
import FastTabSync

/// How the iPhone app is used: on its own as a reader, or as the Mac's companion.
///
/// Compiled into the app and the share extension (`project.yml`, `Shared/AppMode`),
/// so the share sheet offers the right buttons without opening the app.
enum AppMode: String, CaseIterable {
    /// Reader only: save links, read, shuffle. No Tabs tab, no Mac actions.
    case standalone
    /// Paired with FastTab on a Mac: everything, including Tabs and Send to Mac.
    case mac
}

/// Stores the `AppMode` in the app group's defaults (shared with the share extension).
///
/// `nil` means the user has not chosen yet (new install before the guide's first screen).
struct AppModeStore {
    static let modeKey = "appMode.v1"

    let defaults: UserDefaults

    init(defaults: UserDefaults = AppModeStore.sharedDefaults) {
        self.defaults = defaults
    }

    /// The app group suite; falls back to `.standard` only if the group is missing (misconfigured build).
    static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: SyncConstants.appGroupIdentifier) ?? .standard
    }

    var mode: AppMode? {
        get { defaults.string(forKey: Self.modeKey).flatMap(AppMode.init(rawValue:)) }
        nonmutating set { defaults.set(newValue?.rawValue, forKey: Self.modeKey) }
    }

    /// The stored mode, or for an install from before modes existed: `mac` when the
    /// guide was already done or a Mac has synced (they are set up as companions).
    /// Still `nil` for a genuinely new user, who picks on the guide's first screen.
    static func resolve(stored: AppMode?, onboardingCompleted: Bool, hasCachedMac: Bool) -> AppMode? {
        if let stored { return stored }
        return (onboardingCompleted || hasCachedMac) ? .mac : nil
    }

    /// Resolves and persists the migration, so the share extension sees it too.
    @discardableResult
    func resolveAndPersist(onboardingCompleted: Bool, hasCachedMac: Bool) -> AppMode? {
        let resolved = Self.resolve(stored: mode, onboardingCompleted: onboardingCompleted, hasCachedMac: hasCachedMac)
        if mode == nil, let resolved { mode = resolved }
        return resolved
    }

    /// A Mac showing up in sync turns a reader-only phone into a companion.
    /// One way only: a Mac disappearing never switches back (the user can, in More).
    static func modeAfterMacAppeared(current: AppMode?) -> AppMode? {
        current == .standalone ? .mac : current
    }
}

/// One button on the share sheet card.
enum ShareOption: Equatable {
    case sendToMac
    case saveToIPhone
}

enum ShareOptions {
    /// Reader-only phones just save. Companions send first. Undecided: both, save last.
    static func `for`(mode: AppMode?) -> [ShareOption] {
        switch mode {
        case .standalone: return [.saveToIPhone]
        case .mac, nil: return [.sendToMac, .saveToIPhone]
        }
    }
}
