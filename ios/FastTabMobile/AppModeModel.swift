import SwiftUI

/// The app's live `AppMode`, so the root tabs, Read, Shuffle and More redraw when it changes.
/// Persists through `AppModeStore` (app group), where the share extension reads it.
@MainActor
final class AppModeModel: ObservableObject {
    static let shared = AppModeModel()

    /// `nil` until the user answers the guide's first question (or a migration decides).
    @Published private(set) var mode: AppMode?

    private let store: AppModeStore

    init(store: AppModeStore = AppModeStore()) {
        self.store = store
        self.mode = store.mode
    }

    /// Reader only, Tabs hidden. An undecided user sees the full app until they answer.
    var isStandalone: Bool { mode == .standalone }

    func set(_ newMode: AppMode) {
        store.mode = newMode
        mode = newMode
    }

    /// First launch after an update: users who already finished the guide or have a
    /// Mac synced become `mac` without being asked.
    func resolveOnLaunch(onboardingCompleted: Bool, hasCachedMac: Bool) {
        mode = store.resolveAndPersist(onboardingCompleted: onboardingCompleted, hasCachedMac: hasCachedMac)
    }

    /// Call when sync goes from no Mac to a Mac. Returns `true` when that switched
    /// a reader-only phone to `mac` (the caller says so in a toast).
    func macAppeared() -> Bool {
        guard let next = AppModeStore.modeAfterMacAppeared(current: mode), next != mode else { return false }
        set(next)
        return true
    }
}
