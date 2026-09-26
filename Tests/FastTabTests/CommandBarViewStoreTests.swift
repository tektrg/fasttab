import Foundation
import Testing
@testable import FastTab

struct CommandBarViewStoreTests {
    @MainActor
    @Test func existingUserDefaultsToRecentsWithoutWritingToDefaults() {
        let suiteName = "test.fasttab.viewstore.existing.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Mark onboarding completed
        defaults.set(true, forKey: "onboarding.v1.completed")

        let store = CommandBarViewStore(defaults: defaults)
        #expect(store.defaultView == .recents)
        #expect(store.activeView == .recents)

        // Ensure init did NOT write back to defaults
        #expect(defaults.string(forKey: CommandBarViewStore.defaultViewKey) == nil)
    }

    @MainActor
    @Test func freshInstallDefaultsToStackWithoutWritingToDefaults() {
        let suiteName = "test.fasttab.viewstore.fresh.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = CommandBarViewStore(defaults: defaults)
        #expect(store.defaultView == .stack)
        #expect(store.activeView == .stack)

        // Ensure init did NOT write back to defaults
        #expect(defaults.string(forKey: CommandBarViewStore.defaultViewKey) == nil)
    }

    @MainActor
    @Test func explicitSavedDefaultIsPreserved() {
        let suiteName = "test.fasttab.viewstore.explicit.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(CommandBarView.stack.rawValue, forKey: CommandBarViewStore.defaultViewKey)

        let store = CommandBarViewStore(defaults: defaults)
        #expect(store.defaultView == .stack)
        #expect(store.activeView == .stack)
    }

    @MainActor
    @Test func legacyMyOrderDefaultMigratesToStack() {
        let suiteName = "test.fasttab.viewstore.migrate.myorder.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("myOrder", forKey: CommandBarViewStore.defaultViewKey)

        let store = CommandBarViewStore(defaults: defaults)
        #expect(store.defaultView == .stack)
        #expect(store.activeView == .stack)
    }

    @MainActor
    @Test func legacyBookmarksDefaultFallsBackToRecents() {
        let suiteName = "test.fasttab.viewstore.migrate.bookmarks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("bookmarks", forKey: CommandBarViewStore.defaultViewKey)

        let store = CommandBarViewStore(defaults: defaults)
        #expect(store.defaultView == .recents)
        #expect(store.activeView == .recents)
    }

    @MainActor
    @Test func selectViewChangesActiveViewWithoutAlteringDefaultView() {
        let suiteName = "test.fasttab.viewstore.select.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = CommandBarViewStore(defaults: defaults)
        store.setDefaultView(.recents, defaults: defaults)

        store.selectView(.stack)
        #expect(store.activeView == .stack)
        #expect(store.defaultView == .recents)

        store.resetForOpen()
        #expect(store.activeView == .recents)
    }

    @MainActor
    @Test func hoverDefaultViewDefaultsToRecentsWithoutWritingToDefaults() {
        let suiteName = "test.fasttab.viewstore.hover.default.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = CommandBarViewStore(defaults: defaults)
        #expect(store.hoverDefaultView == .recents)
        #expect(defaults.string(forKey: CommandBarViewStore.hoverDefaultViewKey) == nil)

        // Switch to another view then call resetForHoverOpen
        store.selectView(.stack)
        #expect(store.activeView == .stack)

        store.resetForHoverOpen()
        #expect(store.activeView == .recents)
    }

    @MainActor
    @Test func explicitSavedHoverDefaultIsPreserved() {
        let suiteName = "test.fasttab.viewstore.hover.explicit.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(CommandBarView.stack.rawValue, forKey: CommandBarViewStore.hoverDefaultViewKey)

        let store = CommandBarViewStore(defaults: defaults)
        #expect(store.hoverDefaultView == .stack)

        store.selectView(.recents)
        #expect(store.activeView == .recents)

        store.resetForHoverOpen()
        #expect(store.activeView == .stack)

        store.setHoverDefaultView(.recents, defaults: defaults)
        #expect(store.hoverDefaultView == .recents)
        #expect(defaults.string(forKey: CommandBarViewStore.hoverDefaultViewKey) == CommandBarView.recents.rawValue)
    }

    @MainActor
    @Test func slideDirectionCalculationOnForwardAndBackwardTransitions() {
        let store = CommandBarViewStore()
        store.resetForOpen(to: .recents)
        #expect(store.activeView == .recents)

        // Forward transition: recents (0) -> stack (1)
        store.selectView(.stack)
        #expect(store.activeView == .stack)
        #expect(store.slideDirection == .forward)

        // Backward transition: stack (1) -> recents (0)
        store.selectView(.recents)
        #expect(store.activeView == .recents)
        #expect(store.slideDirection == .backward)
    }

    @Test func commandBarViewIndicesAndOrder() {
        #expect(CommandBarView.recents.index == 0)
        #expect(CommandBarView.stack.index == 1)
    }
}
