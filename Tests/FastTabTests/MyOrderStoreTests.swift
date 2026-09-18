import Foundation
import Testing
@testable import FastTab

struct MyOrderStoreTests {
    @MainActor
    @Test func persistenceAndReloadPreservesOrder() {
        let suiteName = "test.fasttab.myorder.persist.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store1 = MyOrderStore(defaults: defaults)
        let tabA = BrowserSearchResult(title: "A", url: "https://a.com", browserName: "Google Chrome", type: .tab, timestamp: Date())
        let tabB = BrowserSearchResult(title: "B", url: "https://b.com", browserName: "Google Chrome", type: .tab, timestamp: Date())

        store1.reconcile(liveTabs: [tabA, tabB], runningBrowsers: ["Google Chrome"])
        store1.flush()

        #expect(store1.slots.count == 2)
        #expect(store1.slots.map(\.title) == ["A", "B"])

        // Second instance loading from same defaults
        let store2 = MyOrderStore(defaults: defaults)
        #expect(store2.slots.count == 2)
        #expect(store2.slots.map(\.title) == ["A", "B"])
    }

    @MainActor
    @Test func secondClosePermanentlyDeletesSlot() {
        let suiteName = "test.fasttab.myorder.close.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = MyOrderStore(defaults: defaults)
        let tabA = BrowserSearchResult(title: "A", url: "https://a.com", browserName: "Google Chrome", type: .tab, timestamp: Date(), isPinned: true)
        store.reconcile(liveTabs: [tabA], runningBrowsers: ["Google Chrome"])

        let slotID = store.slots[0].slotID

        // First close: becomes ghost because it's pinned
        store.closeSlot(slotID)
        #expect(store.slots.count == 1)
        #expect(store.slots[0].state == .ghost)

        // Second close on ghost: permanently deleted!
        store.closeSlot(slotID)
        #expect(store.slots.isEmpty)
    }

    @MainActor
    @Test func closeSlotOnUnpinnedTabDeletesImmediately() {
        let suiteName = "test.fasttab.myorder.closeunpinned.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = MyOrderStore(defaults: defaults)
        let tabA = BrowserSearchResult(title: "A", url: "https://a.com", browserName: "Google Chrome", type: .tab, timestamp: Date(), isPinned: false)
        store.reconcile(liveTabs: [tabA], runningBrowsers: ["Google Chrome"])

        let slotID = store.slots[0].slotID

        // Close on unpinned: immediately deleted (no ghost)!
        store.closeSlot(slotID)
        #expect(store.slots.isEmpty)
    }

    @MainActor
    @Test func togglePinSlotPromotesToTopAndUnpinGhostDeletes() {
        let suiteName = "test.fasttab.myorder.togglepin.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = MyOrderStore(defaults: defaults)
        var pinCalls: [(BrowserSearchResult, Bool)] = []
        store.bindToService(
            closer: { _ in },
            activator: { _ in },
            reopener: { _ in },
            canceller: { _, _ in },
            pinner: { tab, pinned in
                pinCalls.append((tab, pinned))
            }
        )

        let tabA = BrowserSearchResult(title: "A", url: "https://a.com", browserName: "Google Chrome", type: .tab, timestamp: Date(), isPinned: false)
        let tabB = BrowserSearchResult(title: "B", url: "https://b.com", browserName: "Google Chrome", type: .tab, timestamp: Date(), isPinned: false)
        store.reconcile(liveTabs: [tabA, tabB], runningBrowsers: ["Google Chrome"])

        #expect(store.slots.map(\.title) == ["A", "B"])

        // Toggle pin on B -> should call pinner, pin B, and sort B to top
        let slotBID = store.slots[1].slotID
        store.togglePinSlot(slotBID)

        #expect(pinCalls.count == 1)
        #expect(pinCalls[0].0.title == "B")
        #expect(pinCalls[0].1 == true)
        #expect(store.slots.map(\.title) == ["B", "A"])
        #expect(store.slots[0].isPinned == true)

        // Close B -> since it is pinned, it becomes a ghost
        store.closeSlot(slotBID)
        #expect(store.slots.count == 2)
        #expect(store.slots[0].state == .ghost)

        // Toggle pin on ghost B -> unpins and permanently deletes it!
        store.togglePinSlot(slotBID)
        #expect(store.slots.count == 1)
        #expect(store.slots.map(\.title) == ["A"])
    }

    @MainActor
    @Test func dragGuardPreventsReconcileMutation() {
        let suiteName = "test.fasttab.myorder.drag.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = MyOrderStore(defaults: defaults)
        let tabA = BrowserSearchResult(title: "A", url: "https://a.com", browserName: "Google Chrome", type: .tab, timestamp: Date())
        store.reconcile(liveTabs: [tabA], runningBrowsers: ["Google Chrome"])

        store.isDragging = true
        // Try reconcile while dragging
        store.reconcile(liveTabs: [], runningBrowsers: ["Google Chrome"])

        // Slot must still exist because isDragging guarded against mutation
        #expect(store.slots.count == 1)
        #expect(store.slots[0].title == "A")

        store.isDragging = false
    }

    @MainActor
    @Test func reopenGhostSlotInvokesTabReopenerAndClearsTombstone() {
        let suiteName = "test.fasttab.myorder.reopen.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = MyOrderStore(defaults: defaults)
        var cancelledBrowser: String?
        var cancelledURL: String?
        var reopenedURL: String?

        store.bindToService(
            closer: { _ in },
            activator: { _ in },
            reopener: { reopenedURL = $0.url },
            canceller: { b, u in
                cancelledBrowser = b
                cancelledURL = u
            }
        )

        let tabA = BrowserSearchResult(title: "A", url: "https://a.com", browserName: "Google Chrome", type: .tab, timestamp: Date(), isPinned: true)
        store.reconcile(liveTabs: [tabA], runningBrowsers: ["Google Chrome"])
        let slotID = store.slots[0].slotID

        // Close to ghost
        store.closeSlot(slotID)
        #expect(store.slots[0].state == .ghost)

        // Reopen
        store.reopenSlot(slotID)
        #expect(cancelledBrowser == "Google Chrome")
        #expect(cancelledURL == "https://a.com")
        #expect(reopenedURL == "https://a.com")
        #expect(store.slots[0].state == .live)
    }

    @MainActor
    @Test func reorderSlotWithinPinnedSectionPreservesPinnedState() {
        let suiteName = "test.fasttab.myorder.reorder.pinned.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = MyOrderStore(defaults: defaults)
        var pinCalls: [(BrowserSearchResult, Bool)] = []
        store.bindToService(
            closer: { _ in },
            activator: { _ in },
            reopener: { _ in },
            canceller: { _, _ in },
            pinner: { tab, pinned in
                pinCalls.append((tab, pinned))
            }
        )

        let tabP1 = BrowserSearchResult(title: "P1", url: "https://p1.com", browserName: "Google Chrome", type: .tab, timestamp: Date(), isPinned: true)
        let tabP2 = BrowserSearchResult(title: "P2", url: "https://p2.com", browserName: "Google Chrome", type: .tab, timestamp: Date(), isPinned: true)
        let tabU1 = BrowserSearchResult(title: "U1", url: "https://u1.com", browserName: "Google Chrome", type: .tab, timestamp: Date(), isPinned: false)
        let tabU2 = BrowserSearchResult(title: "U2", url: "https://u2.com", browserName: "Google Chrome", type: .tab, timestamp: Date(), isPinned: false)

        store.reconcile(liveTabs: [tabP1, tabP2, tabU1, tabU2], runningBrowsers: ["Google Chrome"])
        #expect(store.slots.map(\.title) == ["P1", "P2", "U1", "U2"])

        // Drag P1 (index 0) down to index 1 (swapping with P2 within pinned section)
        store.reorderSlot(from: 0, to: 1)

        // Neither P1 nor P2 should have been unpinned! No pinCalls should have occurred!
        #expect(pinCalls.isEmpty)
        #expect(store.slots.map(\.title) == ["P2", "P1", "U1", "U2"])
        #expect(store.slots[0].isPinned == true)
        #expect(store.slots[1].isPinned == true)
        #expect(store.slots[2].isPinned == false)
        #expect(store.slots[3].isPinned == false)
    }

    @MainActor
    @Test func reorderSlotAcrossBoundaryUpdatesPinnedState() {
        let suiteName = "test.fasttab.myorder.reorder.boundary.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = MyOrderStore(defaults: defaults)
        var pinCalls: [(BrowserSearchResult, Bool)] = []
        store.bindToService(
            closer: { _ in },
            activator: { _ in },
            reopener: { _ in },
            canceller: { _, _ in },
            pinner: { tab, pinned in
                pinCalls.append((tab, pinned))
            }
        )

        let tabP1 = BrowserSearchResult(title: "P1", url: "https://p1.com", browserName: "Google Chrome", type: .tab, timestamp: Date(), isPinned: true)
        let tabP2 = BrowserSearchResult(title: "P2", url: "https://p2.com", browserName: "Google Chrome", type: .tab, timestamp: Date(), isPinned: true)
        let tabU1 = BrowserSearchResult(title: "U1", url: "https://u1.com", browserName: "Google Chrome", type: .tab, timestamp: Date(), isPinned: false)

        store.reconcile(liveTabs: [tabP1, tabP2, tabU1], runningBrowsers: ["Google Chrome"])
        #expect(store.slots.map(\.title) == ["P1", "P2", "U1"])

        // Drag P1 (index 0) into unpinned section (destination index 2)
        store.reorderSlot(from: 0, to: 2)

        #expect(pinCalls.count == 1)
        #expect(pinCalls[0].0.title == "P1")
        #expect(pinCalls[0].1 == false)
        #expect(store.slots.map(\.title) == ["P2", "U1", "P1"])
        #expect(store.slots[0].isPinned == true)
        #expect(store.slots[1].isPinned == false)
        #expect(store.slots[2].isPinned == false)

        // Now drag U1 (index 1) into pinned section (destination index 0)
        store.reorderSlot(from: 1, to: 0)

        #expect(pinCalls.count == 2)
        #expect(pinCalls[1].0.title == "U1")
        #expect(pinCalls[1].1 == true)
        #expect(store.slots.map(\.title) == ["U1", "P2", "P1"])
        #expect(store.slots[0].isPinned == true)
        #expect(store.slots[1].isPinned == true)
        #expect(store.slots[2].isPinned == false)
    }

    @MainActor
    @Test func ghostRevivalPreservesPinnedStateInStore() {
        let suiteName = "test.fasttab.myorder.ghost.pin.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = MyOrderStore(defaults: defaults)
        var pinCalls: [(BrowserSearchResult, Bool)] = []
        store.bindToService(
            closer: { _ in },
            activator: { _ in },
            reopener: { _ in },
            canceller: { _, _ in },
            pinner: { tab, pinned in
                pinCalls.append((tab, pinned))
            }
        )

        let tabA = BrowserSearchResult(title: "A", url: "https://a.com", browserName: "Google Chrome", type: .tab, timestamp: Date(), isPinned: true)
        store.reconcile(liveTabs: [tabA], runningBrowsers: ["Google Chrome"])
        let slotID = store.slots[0].slotID

        // Close to ghost
        store.closeSlot(slotID)
        #expect(store.slots[0].state == .ghost)
        #expect(store.slots[0].isPinned == true)

        // Browser finishes closing tab
        store.reconcile(liveTabs: [], runningBrowsers: ["Google Chrome"])
        #expect(store.slots[0].state == .ghost)

        // Browser opens tab as UNPINNED (isPinned: false)
        let tabAFromBrowser = BrowserSearchResult(title: "A", url: "https://a.com", browserName: "Google Chrome", type: .tab, timestamp: Date(), tabID: 201, isPinned: false)
        store.reconcile(liveTabs: [tabAFromBrowser], runningBrowsers: ["Google Chrome"])

        // Slot must be revived as live, PRESERVE isPinned == true
        #expect(store.slots[0].state == .live)
        #expect(store.slots[0].isPinned == true)
        #expect(pinCalls.isEmpty)
    }

    @MainActor
    @Test func nonExtensionBrowserDoesNotTriggerErroneousTabPinnerOnReconcile() {
        let suiteName = "test.fasttab.myorder.nonextension.pin.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = MyOrderStore(defaults: defaults)
        var pinCalls: [(BrowserSearchResult, Bool)] = []
        store.bindToService(
            closer: { _ in },
            activator: { _ in },
            reopener: { _ in },
            canceller: { _, _ in },
            pinner: { tab, pinned in
                pinCalls.append((tab, pinned))
            }
        )

        // Safari tabs have tabID == nil
        let safariTab1 = BrowserSearchResult(title: "Safari 1", url: "https://apple.com", browserName: "Safari", type: .tab, timestamp: Date(), tabID: nil, isPinned: false)
        let safariTab2 = BrowserSearchResult(title: "Safari 2", url: "https://webkit.org", browserName: "Safari", type: .tab, timestamp: Date(), tabID: nil, isPinned: false)

        store.reconcile(liveTabs: [safariTab1, safariTab2], runningBrowsers: ["Safari"])
        #expect(store.slots.count == 2)

        // Pin the first slot
        store.togglePinSlot(store.slots[0].slotID)
        #expect(store.slots[0].isPinned == true)
        #expect(pinCalls.count == 1) // One call from user toggle
        pinCalls.removeAll()

        // Reconcile runs again (e.g. background poll)
        store.reconcile(liveTabs: [safariTab1, safariTab2], runningBrowsers: ["Safari"])

        // Pin must NOT trigger repeated tabPinner calls due to nil == nil boundTabID match
        #expect(pinCalls.isEmpty)
        #expect(store.slots[0].isPinned == true)
    }

    @MainActor
    @Test func urlsMatchSupportsTrailingSlashAndRedirectsInStore() {
        let suiteName = "test.fasttab.myorder.urlsmatch.store.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = MyOrderStore(defaults: defaults)
        let tab = BrowserSearchResult(title: "Root", url: "https://example.com/", browserName: "Google Chrome", type: .tab, timestamp: Date(), tabID: 501, isPinned: true)
        store.reconcile(liveTabs: [tab], runningBrowsers: ["Google Chrome"])
        #expect(store.slots.count == 1)
        #expect(store.slots[0].isPinned == true)

        // Close to ghost
        store.closeSlot(store.slots[0].slotID)
        #expect(store.slots[0].state == .ghost)

        // Remote close with no trailing slash and no tabID matches the slot
        store.recordRemoteClose(browserName: "Google Chrome", url: "https://example.com", tabID: nil)
        // Since it was already a ghost, recordRemoteClose matches and keeps it as ghost
        #expect(store.slots.count == 1)

        // setSlotPinned with http URL (redirect variant) unpins ghost -> deletes it permanently
        store.setSlotPinned(browserName: "Google Chrome", url: "http://example.com", tabID: nil, isPinned: false)
        #expect(store.slots.isEmpty)
    }

    @MainActor
    @Test func pinningTabAbsentFromSlotsCreatesPinnedSlot() {
        let suiteName = "test.fasttab.myorder.absentpin.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = MyOrderStore(defaults: defaults)
        #expect(store.slots.isEmpty)

        store.setSlotPinned(browserName: "Safari", url: "https://news.ycombinator.com", tabID: nil, isPinned: true)
        #expect(store.slots.count == 1)
        #expect(store.slots[0].url == "https://news.ycombinator.com")
        #expect(store.slots[0].isPinned == true)
        #expect(store.slots[0].confirmedInBrowser == false)
        #expect(store.isSlotPinned(browserName: "Safari", url: "https://news.ycombinator.com", tabID: nil) == true)
    }

    @MainActor
    @Test func safariTabPinnedInternallyPersistsAcrossReconciliation() {
        let suiteName = "test.fasttab.myorder.safari.persist.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = MyOrderStore(defaults: defaults)
        let safariTab = BrowserSearchResult(title: "Hacker News", url: "https://news.ycombinator.com", browserName: "Safari", type: .tab, timestamp: Date(), tabID: nil, isPinned: false)

        store.reconcile(liveTabs: [safariTab], runningBrowsers: ["Safari"])
        #expect(store.slots.count == 1)
        #expect(store.slots[0].isPinned == false)

        // Pin in FastTab
        store.setSlotPinned(browserName: "Safari", url: "https://news.ycombinator.com", tabID: nil, isPinned: true)
        #expect(store.slots[0].isPinned == true)
        #expect(store.slots[0].confirmedInBrowser == false)

        // Background poll comes back from Safari with isPinned: false
        store.reconcile(liveTabs: [safariTab], runningBrowsers: ["Safari"])
        #expect(store.slots[0].isPinned == true)

        // overlayPinStatus decorates the raw live tab
        let overlaid = store.overlayPinStatus(on: [safariTab])
        #expect(overlaid[0].isPinned == true)
    }

    @MainActor
    @Test func unconfirmedChromiumTabPinnedInternallyPersistsAcrossReconciliation() {
        let suiteName = "test.fasttab.myorder.chrome.unconfirmed.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = MyOrderStore(defaults: defaults)
        let chromeTab = BrowserSearchResult(title: "Docs", url: "https://docs.google.com", browserName: "Google Chrome", type: .tab, timestamp: Date(), tabID: 101, isPinned: false)

        store.reconcile(liveTabs: [chromeTab], runningBrowsers: ["Google Chrome"])
        #expect(store.slots[0].isPinned == false)

        // User pins tab in FastTab, but extension hasn't confirmed native pin yet
        store.setSlotPinned(browserName: "Google Chrome", url: "https://docs.google.com", tabID: 101, isPinned: true)
        #expect(store.slots[0].isPinned == true)
        #expect(store.slots[0].confirmedInBrowser == false)

        // Poll arrives while extension is still pending/failed (isPinned: false)
        store.reconcile(liveTabs: [chromeTab], runningBrowsers: ["Google Chrome"])
        #expect(store.slots[0].isPinned == true)
    }

    @MainActor
    @Test func tabPinnedInFastTabPersistsEvenIfBrowserReportsUnpinnedAndOnlyUnpinsViaFastTab() {
        let suiteName = "test.fasttab.myorder.chrome.appowned.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = MyOrderStore(defaults: defaults)
        // Tab starts natively pinned in browser
        let pinnedTab = BrowserSearchResult(title: "Docs", url: "https://docs.google.com", browserName: "Google Chrome", type: .tab, timestamp: Date(), tabID: 101, isPinned: true)

        store.reconcile(liveTabs: [pinnedTab], runningBrowsers: ["Google Chrome"])
        #expect(store.slots[0].isPinned == true)

        // Browser reports tab unpinned (e.g. user unpinned in browser)
        let unpinnedTab = BrowserSearchResult(title: "Docs", url: "https://docs.google.com", browserName: "Google Chrome", type: .tab, timestamp: Date(), tabID: 101, isPinned: false)

        store.reconcile(liveTabs: [unpinnedTab], runningBrowsers: ["Google Chrome"])
        // App owns the pin: slot remains pinned in FastTab!
        #expect(store.slots[0].isPinned == true)

        // Only explicitly unpinning in FastTab unpins the slot
        store.togglePinSlot(store.slots[0].slotID)
        #expect(store.slots[0].isPinned == false)
    }

    @MainActor
    @Test func duplicateURLsWithDistinctTabIDsDoNotCrossContaminatePinStatus() {
        let suiteName = "test.fasttab.myorder.chrome.duplicates.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = MyOrderStore(defaults: defaults)
        let tab1 = BrowserSearchResult(title: "Docs 1", url: "https://docs.google.com", browserName: "Google Chrome", type: .tab, timestamp: Date(), tabID: 101, isPinned: false)
        let tab2 = BrowserSearchResult(title: "Docs 2", url: "https://docs.google.com", browserName: "Google Chrome", type: .tab, timestamp: Date(), tabID: 102, isPinned: false)

        store.reconcile(liveTabs: [tab1, tab2], runningBrowsers: ["Google Chrome"])
        #expect(store.slots.count == 2)

        // Pin only tab 101
        store.setSlotPinned(browserName: "Google Chrome", url: "https://docs.google.com", tabID: 101, isPinned: true)
        #expect(store.isSlotPinned(browserName: "Google Chrome", url: "https://docs.google.com", tabID: 101) == true)
        #expect(store.isSlotPinned(browserName: "Google Chrome", url: "https://docs.google.com", tabID: 102) == false)

        let overlaid = store.overlayPinStatus(on: [tab1, tab2])
        #expect(overlaid[0].tabID == 101 && overlaid[0].isPinned == true)
        #expect(overlaid[1].tabID == 102 && overlaid[1].isPinned == false)
    }

    @MainActor
    @Test func confirmedChromiumTabReconciledWithAppleScriptPollPreservesPin() {
        let suiteName = "test.fasttab.myorder.chrome.applescript.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = MyOrderStore(defaults: defaults)
        let chromeTab = BrowserSearchResult(title: "Docs", url: "https://docs.google.com", browserName: "Google Chrome", type: .tab, timestamp: Date(), tabID: 101, isPinned: true)

        store.reconcile(liveTabs: [chromeTab], runningBrowsers: ["Google Chrome"])
        #expect(store.slots[0].isPinned == true)
        #expect(store.slots[0].confirmedInBrowser == true)
        #expect(store.slots[0].boundTabID == 101)

        // AppleScript fallback fetch happens! (tabID is nil, isPinned is false)
        let appleScriptTab = BrowserSearchResult(title: "Docs", url: "https://docs.google.com", browserName: "Google Chrome", type: .tab, timestamp: Date(), tabID: nil, isPinned: false)
        store.reconcile(liveTabs: [appleScriptTab], runningBrowsers: ["Google Chrome"])
        #expect(store.slots[0].isPinned == true)
        #expect(store.slots[0].confirmedInBrowser == true)
        #expect(store.slots[0].boundTabID == 101)

        // overlayPinStatus correctly marks the AppleScript search result as pinned
        let overlaid = store.overlayPinStatus(on: [appleScriptTab])
        #expect(overlaid[0].isPinned == true)

        // Extension subsequently reports user unpinned the tab natively in Chrome
        let unpinnedChromeTab = BrowserSearchResult(title: "Docs", url: "https://docs.google.com", browserName: "Google Chrome", type: .tab, timestamp: Date(), tabID: 101, isPinned: false)
        store.reconcile(liveTabs: [unpinnedChromeTab], runningBrowsers: ["Google Chrome"])
        // App owns the pin: FastTab preserves its pin!
        #expect(store.slots[0].isPinned == true)

        // Only explicitly unpinning in FastTab unpins the slot
        store.togglePinSlot(store.slots[0].slotID)
        #expect(store.slots[0].isPinned == false)
    }

    @MainActor
    @Test func ghostRevivalUnderAppleScriptPollPreservesConfirmedInBrowserAndPins() {
        let suiteName = "test.fasttab.myorder.ghost.applescript.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = MyOrderStore(defaults: defaults)
        let chromeTab = BrowserSearchResult(title: "Work", url: "https://work.com", browserName: "Google Chrome", type: .tab, timestamp: Date(), tabID: 55, isPinned: true)
        store.reconcile(liveTabs: [chromeTab], runningBrowsers: ["Google Chrome"])
        #expect(store.slots[0].isPinned == true)
        #expect(store.slots[0].confirmedInBrowser == true)
        let slotID = store.slots[0].slotID

        // Close to ghost
        store.closeSlot(slotID)
        #expect(store.slots[0].state == .ghost)
        #expect(store.slots[0].isPinned == true)
        #expect(store.slots[0].confirmedInBrowser == true)

        // Browser finishes closing tab
        store.reconcile(liveTabs: [], runningBrowsers: ["Google Chrome"])
        #expect(store.slots[0].state == .ghost)

        // AppleScript fallback poll revives tab (tabID == nil, isPinned == false)
        let appleScriptTab = BrowserSearchResult(title: "Work", url: "https://work.com", browserName: "Google Chrome", type: .tab, timestamp: Date(), tabID: nil, isPinned: false)
        store.reconcile(liveTabs: [appleScriptTab], runningBrowsers: ["Google Chrome"])

        // Revives as live, remains pinned, and preserves confirmedInBrowser!
        #expect(store.slots[0].state == .live)
        #expect(store.slots[0].isPinned == true)
        #expect(store.slots[0].confirmedInBrowser == true)
    }

    @MainActor
    @Test func setSlotPinnedUpdatesExistingSlotWhenTabIDChanged() {
        let suiteName = "test.fasttab.myorder.tabidswap.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = MyOrderStore(defaults: defaults)
        let notionURL = "https://app.notion.com/p/UX-Consolidated-Live-Feedback-09-April-onwards-88ddcc150a784e70bb44fa007b75a194"
        let initialTab = BrowserSearchResult(
            title: "UX Notion",
            url: notionURL,
            browserName: "Microsoft Edge",
            type: .tab,
            timestamp: Date(),
            tabID: 484801435,
            isPinned: true
        )

        store.reconcile(liveTabs: [initialTab], runningBrowsers: ["Microsoft Edge"])
        #expect(store.slots.count == 1)
        #expect(store.slots[0].boundTabID == 484801435)

        // Chromium sleeping tab wakes up or discards, getting a new tabID
        store.setSlotPinned(
            browserName: "Microsoft Edge",
            url: notionURL,
            tabID: 484802241,
            isPinned: true
        )

        // MUST NOT create a duplicate slot!
        #expect(store.slots.count == 1)
        #expect(store.slots[0].url == notionURL)
    }

    @MainActor
    @Test func loadSlotsDeduplicatesStoredDuplicateSlots() {
        let suiteName = "test.fasttab.myorder.storeddups.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let notionURL = "https://app.notion.com/p/UX-Consolidated-Live-Feedback-09-April-onwards-88ddcc150a784e70bb44fa007b75a194"
        let slot1 = OrderedTabSlot(
            slotID: UUID(),
            url: notionURL,
            title: "UX Notion 1",
            browserName: "Microsoft Edge",
            state: .live,
            boundTabID: 484802241,
            isPinned: true
        )
        let slot2 = OrderedTabSlot(
            slotID: UUID(),
            url: notionURL,
            title: "UX Notion 2",
            browserName: "Microsoft Edge",
            state: .live,
            boundTabID: 484801435,
            isPinned: true
        )

        let data = try! JSONEncoder().encode([slot1, slot2])
        defaults.set(data, forKey: MyOrderStore.slotsKey)

        let store = MyOrderStore(defaults: defaults)
        // Stored duplicates must be collapsed!
        #expect(store.slots.count == 1)
        #expect(store.slots[0].isPinned == true)
    }
}



