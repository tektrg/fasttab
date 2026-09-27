import Foundation
import Testing
@testable import FastTab

/// The store follows the extension setting via `UserDefaults.didChangeNotification`,
/// which fires on whatever thread wrote any default.
///
/// Other suites flip `ExtensionBetaPreference` too, so assertions poll for
/// "store mirrors the stored setting" instead of pinning a value at one instant.
@MainActor
@Suite(.serialized)
struct AutomationPermissionStoreLiveSettingTests {
    /// Regression: an off-main write of an unrelated default used to trap the
    /// app (main-actor-isolated Combine closure running on a background thread).
    @Test func offMainDefaultsWriteDoesNotTrap() async {
        let store = AutomationPermissionStore()
        let probeKey = "FastTab.tests.offMainDefaultsWriteProbe"
        await Task.detached {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: probeKey)
        }.value
        #expect(await eventuallyMirrorsSetting(store))
        UserDefaults.standard.removeObject(forKey: probeKey)
    }

    /// Settings > Advanced toggle → onboarding: flipping the stored setting
    /// (what `@AppStorage` does) re-renders the extension step's state.
    @Test func followsSettingWrittenElsewhere() async {
        let store = AutomationPermissionStore()
        defer { ExtensionBetaPreference.setEnabled(false) }

        ExtensionBetaPreference.setEnabled(!store.isExtensionFeatureEnabled)
        #expect(await eventuallyMirrorsSetting(store))

        ExtensionBetaPreference.setEnabled(!store.isExtensionFeatureEnabled)
        #expect(await eventuallyMirrorsSetting(store))
    }

    /// Onboarding → Settings: "Turn on the extension" writes the same setting
    /// the Settings toggle reads, and the store reflects it at once.
    @Test func turnOnExtensionFeatureWritesTheSetting() {
        ExtensionBetaPreference.setEnabled(false)
        defer { ExtensionBetaPreference.setEnabled(false) }
        let store = AutomationPermissionStore()

        store.turnOnExtensionFeature()

        #expect(UserDefaults.standard.bool(forKey: ExtensionBetaPreference.defaultsKey))
        #expect(store.isExtensionFeatureEnabled)
    }

    private func eventuallyMirrorsSetting(_ store: AutomationPermissionStore) async -> Bool {
        for _ in 0..<40 {
            if store.isExtensionFeatureEnabled == ExtensionBetaPreference.isEnabled { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }
}
