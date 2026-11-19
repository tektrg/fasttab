import Foundation
import IndieOnboarding

/// Whether this install has finished (or skipped) onboarding — the one "existing user" signal
/// `EdgeRevealStore`, `CommandBarViewStore` and `ShortcutStore` branch on for their first-run
/// defaults.
///
/// The key shipped in May 2026 and predates IndieOnboarding's versioned keys. It stays verbatim:
/// renaming it would show onboarding again to every existing install.
enum FastTabOnboarding {
    static let completedKey = "onboarding.v1.completed"

    static func completion(defaults: UserDefaults = .standard) -> OnboardingCompletionStore {
        OnboardingCompletionStore(key: completedKey, defaults: defaults)
    }

    static func isCompleted(in defaults: UserDefaults = .standard) -> Bool {
        completion(defaults: defaults).isCompleted
    }
}
