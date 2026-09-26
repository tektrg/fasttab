import Foundation
import Testing
@testable import FastTab

/// The store follows the extension setting via `UserDefaults.didChangeNotification`,
/// which fires on whatever thread wrote any default.
@MainActor
struct AutomationPermissionStoreLiveSettingTests {
    /// Regression: an off-main write of an unrelated default used to trap the
    /// app (main-actor-isolated Combine closure running on a background thread).
    @Test func offMainDefaultsWriteDoesNotTrap() async {
        let store = AutomationPermissionStore()
        let probeKey = "FastTab.tests.offMainDefaultsWriteProbe"
        await Task.detached {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: probeKey)
        }.value
        try? await Task.sleep(for: .milliseconds(200))
        #expect(store.isExtensionFeatureEnabled == ExtensionBetaPreference.isEnabled)
        UserDefaults.standard.removeObject(forKey: probeKey)
    }
}
