import Foundation

/// Remembers that the first-run guide was finished or skipped.
///
/// Same key as the Mac app (`onboarding.v1.completed`, `Sources/FastTab/OnboardingView.swift`):
/// bump the version suffix to show a redesigned guide to everyone once more.
struct OnboardingCompletionStore {
    static let completedKey = "onboarding.v1.completed"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isCompleted: Bool { defaults.bool(forKey: Self.completedKey) }

    func markCompleted() {
        defaults.set(true, forKey: Self.completedKey)
    }

    /// Decides once per launch whether the guide opens by itself, and records
    /// an upgrading user as done (see below).
    ///
    /// Someone updating from a build without onboarding already has a Mac in the
    /// sync cache: they are set up, so the guide stays out of their way (it is
    /// still under More → Setup Guide) and is marked done so it never pops up
    /// later, e.g. after they remove that Mac.
    func resolveLaunchPresentation(hasCachedMac: Bool) -> Bool {
        guard !isCompleted else { return false }
        if hasCachedMac {
            markCompleted()
            return false
        }
        return true
    }
}
