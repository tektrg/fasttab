import Foundation
import Testing
@testable import FastTab

@MainActor
struct PinnedTabOtherBrowserTests {
    private func freshDefaults() -> UserDefaults {
        let suite = "PinnedTabOtherBrowserTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func otherBrowsersExcludesCurrentAndFinderAndPromotesLastChosen() {
        let list = FastTabRowMenu.otherBrowsers(
            excluding: "Google Chrome",
            available: ["Google Chrome", "Microsoft Edge", "Ardia", "Safari", "Finder"],
            lastChosen: "Ardia"
        )
        #expect(list == ["Ardia", "Microsoft Edge", "Safari"])
    }

    @Test func menuShowsOpenInOtherBrowserOnlyForPinnedTabs() {
        let pinnedTab = BrowserSearchResult(
            title: "Docs",
            url: "https://example.com/docs",
            browserName: "Google Chrome",
            type: .tab,
            timestamp: Date(),
            isPinned: true
        )
        let unpinnedTab = BrowserSearchResult(
            title: "Docs",
            url: "https://example.com/docs",
            browserName: "Google Chrome",
            type: .tab,
            timestamp: Date(),
            isPinned: false
        )

        let pinnedActions = FastTabRowMenu.actions(
            for: pinnedTab,
            bridge: nil,
            offersPin: true,
            otherBrowsers: ["Ardia", "Safari"]
        )
        let submenu = pinnedActions.first(where: { $0.id == FastTabRowMenu.openInOtherBrowserID })
        #expect(submenu != nil)
        #expect(submenu?.submenu.first?.actions.map(\.title) == ["Ardia", "Safari"])
        #expect(FastTabRowMenu.otherBrowserName(from: submenu!.submenu[0].actions[0].id) == "Ardia")

        let unpinnedActions = FastTabRowMenu.actions(
            for: unpinnedTab,
            bridge: nil,
            offersPin: true,
            otherBrowsers: ["Ardia", "Safari"]
        )
        #expect(!unpinnedActions.contains(where: { $0.id == FastTabRowMenu.openInOtherBrowserID }))
    }

    @Test func openSlotInBrowserRemembersChoiceOnSlotAndStore() {
        let defaults = freshDefaults()
        let store = MyOrderStore(defaults: defaults)

        let chromeTab = BrowserSearchResult(
            title: "Linear",
            url: "https://linear.app",
            browserName: "Google Chrome",
            type: .tab,
            timestamp: Date(),
            windowIndex: 1,
            tabIndex: 2,
            profileName: "Work",
            profileDirectory: "Profile 1",
            tabID: 42,
            isPinned: true
        )
        store.reconcile(liveTabs: [chromeTab], runningBrowsers: ["Google Chrome", "Ardia"])
        let slotID = store.slots[0].slotID

        var openedTarget: (url: String, browser: String)?
        var reopenedBrowser: String?
        store.bindToService(
            closer: { _ in },
            activator: { _ in },
            reopener: { reopenedBrowser = $0.browserName },
            otherBrowserOpener: { result, target in openedTarget = (result.url, target) },
            canceller: { _, _ in }
        )

        store.openSlotInBrowser(slotID, targetBrowserName: "Ardia")

        #expect(openedTarget?.url == "https://linear.app")
        #expect(openedTarget?.browser == "Ardia")
        #expect(store.lastOtherBrowserName == "Ardia")
        #expect(defaults.string(forKey: MyOrderStore.lastOtherBrowserKey) == "Ardia")

        let updated = store.slots[0]
        #expect(updated.browserName == "Ardia")
        #expect(updated.profileName == nil)
        #expect(updated.profileDirectory == nil)
        #expect(updated.boundTabID == nil)
        #expect(updated.isPinned)

        // Subsequent reopen uses the remembered browser ("Ardia").
        store.reopenSlot(slotID)
        #expect(reopenedBrowser == "Ardia")
    }
}
