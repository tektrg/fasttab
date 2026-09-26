import Foundation
import Testing
@testable import FastTab

/// Settings toggles and runtime readers share one key + default per
/// preference; these pin the defaults so the UI can't drift from runtime again.
struct OnboardingDefaultsTests {
    private func freshDefaults() -> (UserDefaults, String) {
        let suiteName = "test.fasttab.onboarding.defaults.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suiteName)!, suiteName)
    }

    @Test func extensionIsOnWhenUnset() {
        let (defaults, suiteName) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(ExtensionBetaPreference.defaultValue == true)
        #expect(ExtensionBetaPreference.isEnabled(in: defaults))

        defaults.set(false, forKey: ExtensionBetaPreference.defaultsKey)
        #expect(!ExtensionBetaPreference.isEnabled(in: defaults))
    }

    @Test func safariFDADataIsOffWhenUnset() {
        let (defaults, suiteName) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(SafariBackend.includeFDADataDefaultValue == false)
        #expect(!SafariBackend.isFDADataIncluded(in: defaults))

        defaults.set(true, forKey: SafariBackend.includeFDADataDefaultsKey)
        #expect(SafariBackend.isFDADataIncluded(in: defaults))
    }

    @Test func recentsEmptyHintNamesEnabledBrowsers() {
        #expect(SearchSource.recentsEmptyHint(enabled: [.chrome]) == "Open a tab in Chrome and try again.")
        #expect(SearchSource.recentsEmptyHint(enabled: [.safari, .chrome, .finder, .brave])
            == "Open a tab in Chrome, Brave or Safari and try again.")
        #expect(SearchSource.recentsEmptyHint(enabled: [.finder]) == "Open a Finder window and try again.")
    }
}
