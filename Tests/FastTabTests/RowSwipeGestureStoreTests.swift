import Foundation
import Testing
@testable import FastTab

struct RowSwipeGestureStoreTests {
    @MainActor
    @Test func freshInstallDefaultsToFalseWithoutWritingToDefaults() {
        let suiteName = "test.fasttab.rowswipe.fresh.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = RowSwipeGestureStore(defaults: defaults)
        #expect(store.isEnabled == false)
        #expect(defaults.object(forKey: RowSwipeGestureStore.swipeGestureEnabledKey) == nil)
    }

    @MainActor
    @Test func existingUserDefaultsToFalseWithoutWritingToDefaults() {
        let suiteName = "test.fasttab.rowswipe.existing.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: "onboarding.v1.completed")

        let store = RowSwipeGestureStore(defaults: defaults)
        #expect(store.isEnabled == false)
        #expect(defaults.object(forKey: RowSwipeGestureStore.swipeGestureEnabledKey) == nil)
    }

    @MainActor
    @Test func explicitSettingPreserved() {
        let suiteName = "test.fasttab.rowswipe.explicit.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: RowSwipeGestureStore.swipeGestureEnabledKey)
        let store1 = RowSwipeGestureStore(defaults: defaults)
        #expect(store1.isEnabled == true)

        store1.isEnabled = false
        #expect(defaults.bool(forKey: RowSwipeGestureStore.swipeGestureEnabledKey) == false)
    }
}
