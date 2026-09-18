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
    @Test func freshInstallDefaultsToMyOrderWithoutWritingToDefaults() {
        let suiteName = "test.fasttab.viewstore.fresh.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = CommandBarViewStore(defaults: defaults)
        #expect(store.defaultView == .myOrder)
        #expect(store.activeView == .myOrder)

        // Ensure init did NOT write back to defaults
        #expect(defaults.string(forKey: CommandBarViewStore.defaultViewKey) == nil)
    }

    @MainActor
    @Test func explicitSavedDefaultIsPreserved() {
        let suiteName = "test.fasttab.viewstore.explicit.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(CommandBarView.bookmarks.rawValue, forKey: CommandBarViewStore.defaultViewKey)

        let store = CommandBarViewStore(defaults: defaults)
        #expect(store.defaultView == .bookmarks)
        #expect(store.activeView == .bookmarks)
    }

    @MainActor
    @Test func selectViewChangesActiveViewWithoutAlteringDefaultView() {
        let suiteName = "test.fasttab.viewstore.select.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = CommandBarViewStore(defaults: defaults)
        store.setDefaultView(.recents, defaults: defaults)

        store.selectView(.myOrder)
        #expect(store.activeView == .myOrder)
        #expect(store.defaultView == .recents)

        store.resetForOpen()
        #expect(store.activeView == .recents)
    }

    @MainActor
    @Test func hoverDefaultViewDefaultsToMyOrderWithoutWritingToDefaults() {
        let suiteName = "test.fasttab.viewstore.hover.default.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = CommandBarViewStore(defaults: defaults)
        #expect(store.hoverDefaultView == .myOrder)
        #expect(defaults.string(forKey: CommandBarViewStore.hoverDefaultViewKey) == nil)

        // Switch to another view then call resetForHoverOpen
        store.selectView(.recents)
        #expect(store.activeView == .recents)

        store.resetForHoverOpen()
        #expect(store.activeView == .myOrder)
    }

    @MainActor
    @Test func explicitSavedHoverDefaultIsPreserved() {
        let suiteName = "test.fasttab.viewstore.hover.explicit.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(CommandBarView.bookmarks.rawValue, forKey: CommandBarViewStore.hoverDefaultViewKey)

        let store = CommandBarViewStore(defaults: defaults)
        #expect(store.hoverDefaultView == .bookmarks)

        store.resetForHoverOpen()
        #expect(store.activeView == .bookmarks)

        store.setHoverDefaultView(.recents, defaults: defaults)
        #expect(store.hoverDefaultView == .recents)
        #expect(defaults.string(forKey: CommandBarViewStore.hoverDefaultViewKey) == CommandBarView.recents.rawValue)
    }

    @MainActor
    @Test func slideDirectionCalculationOnForwardAndBackwardTransitions() {
        let store = CommandBarViewStore()
        store.resetForOpen(to: .recents)
        #expect(store.activeView == .recents)

        // Forward transition: recents (0) -> myOrder (1)
        store.selectView(.myOrder)
        #expect(store.activeView == .myOrder)
        #expect(store.slideDirection == .forward)

        // Forward transition: myOrder (1) -> bookmarks (2)
        store.selectView(.bookmarks)
        #expect(store.activeView == .bookmarks)
        #expect(store.slideDirection == .forward)

        // Backward transition: bookmarks (2) -> recents (0)
        store.selectView(.recents)
        #expect(store.activeView == .recents)
        #expect(store.slideDirection == .backward)

        // Backward transition: myOrder (1) -> recents (0)
        store.selectView(.myOrder)
        store.selectView(.recents)
        #expect(store.activeView == .recents)
        #expect(store.slideDirection == .backward)
    }

    @Test func commandBarViewIndicesAndOrder() {
        #expect(CommandBarView.recents.index == 0)
        #expect(CommandBarView.myOrder.index == 1)
        #expect(CommandBarView.bookmarks.index == 2)
    }
}
