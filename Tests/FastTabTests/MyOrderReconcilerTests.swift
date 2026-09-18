import Foundation
import Testing
@testable import FastTab

struct MyOrderReconcilerTests {
    private func makeTab(
        title: String,
        url: String,
        browser: String = "Google Chrome",
        tabID: Int? = nil,
        win: Int? = 1,
        tabIndex: Int? = 1,
        profile: String? = "Default",
        isPinned: Bool = false
    ) -> BrowserSearchResult {
        BrowserSearchResult(
            title: title,
            url: url,
            browserName: browser,
            type: .tab,
            timestamp: Date(),
            windowIndex: win,
            tabIndex: tabIndex,
            profileName: profile,
            tabID: tabID,
            isPinned: isPinned
        )
    }

    @Test func orderIsStableUnderShuffledLiveTabs() {
        let tabA = makeTab(title: "Tab A", url: "https://a.com", tabID: 101)
        let tabB = makeTab(title: "Tab B", url: "https://b.com", tabID: 102)
        let tabC = makeTab(title: "Tab C", url: "https://c.com", tabID: 103)

        // Initial populate: A, B, C
        let step1 = MyOrderReconciler.reconcile(
            currentSlots: [],
            liveTabs: [tabA, tabB, tabC],
            runningBrowsers: ["Google Chrome"],
            pendingCloses: []
        )
        #expect(step1.slots.map(\.title) == ["Tab A", "Tab B", "Tab C"])

        // Live tabs arrive shuffled: C, A, B
        let step2 = MyOrderReconciler.reconcile(
            currentSlots: step1.slots,
            liveTabs: [tabC, tabA, tabB],
            runningBrowsers: ["Google Chrome"],
            pendingCloses: []
        )
        // Order must remain A, B, C!
        #expect(step2.slots.map(\.title) == ["Tab A", "Tab B", "Tab C"])
    }

    @Test func ghostRevivesAtItsOriginalIndex() {
        let tabA = makeTab(title: "Tab A", url: "https://a.com", tabID: 101, isPinned: true)
        let tabB = makeTab(title: "Tab B", url: "https://b.com", tabID: 102, isPinned: true)
        let tabC = makeTab(title: "Tab C", url: "https://c.com", tabID: 103, isPinned: true)

        let initial = MyOrderReconciler.reconcile(
            currentSlots: [],
            liveTabs: [tabA, tabB, tabC],
            runningBrowsers: ["Google Chrome"],
            pendingCloses: []
        )

        let slotBID = initial.slots[1].slotID

        // Close Tab B via FastTab (intent present)
        let pending = [PendingSlotClose(slotID: slotBID, browserName: "Google Chrome", url: "https://b.com", tabID: 102)]
        let afterClose = MyOrderReconciler.reconcile(
            currentSlots: initial.slots,
            liveTabs: [tabA, tabC], // B is absent from live tabs
            runningBrowsers: ["Google Chrome"],
            pendingCloses: pending
        )

        #expect(afterClose.slots.count == 3)
        #expect(afterClose.slots[1].state == .ghost)
        #expect(afterClose.slots[1].title == "Tab B")
        #expect(afterClose.slots[1].isPinned == true)

        // Reopen Tab B (it reappears in live tabs, possibly with a new tabID)
        let tabBReopened = makeTab(title: "Tab B", url: "https://b.com", tabID: 104, isPinned: true)
        let afterReopen = MyOrderReconciler.reconcile(
            currentSlots: afterClose.slots,
            liveTabs: [tabA, tabC, tabBReopened],
            runningBrowsers: ["Google Chrome"],
            pendingCloses: []
        )

        // B must be revived back in slot index 1!
        #expect(afterReopen.slots.count == 3)
        #expect(afterReopen.slots[1].state == .live)
        #expect(afterReopen.slots[1].title == "Tab B")
        #expect(afterReopen.slots[1].isPinned == true)
        #expect(afterReopen.slots.map(\.title) == ["Tab A", "Tab B", "Tab C"])
    }

    @Test func unpinnedTabCloseVanishesWhilePinnedTabCloseLeavesGhost() {
        let tabA = makeTab(title: "Tab A", url: "https://a.com", tabID: 101, isPinned: false)
        let tabB = makeTab(title: "Tab B", url: "https://b.com", tabID: 102, isPinned: true)

        let initial = MyOrderReconciler.reconcile(
            currentSlots: [],
            liveTabs: [tabA, tabB],
            runningBrowsers: ["Google Chrome"],
            pendingCloses: []
        )

        // Tab B is pinned, Tab A is unpinned -> Tab B is at top
        #expect(initial.slots.map(\.title) == ["Tab B", "Tab A"])

        // Close Tab A in browser without FastTab intent -> vanishes!
        let afterCloseA = MyOrderReconciler.reconcile(
            currentSlots: initial.slots,
            liveTabs: [tabB],
            runningBrowsers: ["Google Chrome"],
            pendingCloses: []
        )
        #expect(afterCloseA.slots.count == 1)
        #expect(afterCloseA.slots[0].title == "Tab B")

        // Close Tab B in browser -> leaves a ghost because Tab B is pinned!
        let afterCloseB = MyOrderReconciler.reconcile(
            currentSlots: afterCloseA.slots,
            liveTabs: [],
            runningBrowsers: ["Google Chrome"],
            pendingCloses: []
        )
        #expect(afterCloseB.slots.count == 1)
        #expect(afterCloseB.slots[0].title == "Tab B")
        #expect(afterCloseB.slots[0].state == .ghost)
        #expect(afterCloseB.slots[0].isPinned == true)
    }

    @Test func pinnedTabsSortToTop() {
        let tabA = makeTab(title: "Tab A", url: "https://a.com", tabID: 101, isPinned: false)
        let tabB = makeTab(title: "Tab B", url: "https://b.com", tabID: 102, isPinned: true)
        let tabC = makeTab(title: "Tab C", url: "https://c.com", tabID: 103, isPinned: false)
        let tabD = makeTab(title: "Tab D", url: "https://d.com", tabID: 104, isPinned: true)

        let result = MyOrderReconciler.reconcile(
            currentSlots: [],
            liveTabs: [tabA, tabB, tabC, tabD],
            runningBrowsers: ["Google Chrome"],
            pendingCloses: []
        )

        // Pinned tabs B & D first, then unpinned A & C
        #expect(result.slots.map(\.title) == ["Tab B", "Tab D", "Tab A", "Tab C"])
        #expect(result.slots[0].isPinned == true)
        #expect(result.slots[1].isPinned == true)
        #expect(result.slots[2].isPinned == false)
        #expect(result.slots[3].isPinned == false)
    }

    @Test func nonRunningBrowserFreezesSlots() {
        let tabA = makeTab(title: "Tab A", url: "https://a.com", tabID: 101)

        let initial = MyOrderReconciler.reconcile(
            currentSlots: [],
            liveTabs: [tabA],
            runningBrowsers: ["Google Chrome"],
            pendingCloses: []
        )

        // Google Chrome quit: not running, 0 live tabs
        let afterQuit = MyOrderReconciler.reconcile(
            currentSlots: initial.slots,
            liveTabs: [],
            runningBrowsers: [], // Chrome not running
            pendingCloses: []
        )

        #expect(afterQuit.slots.count == 1)
        #expect(afterQuit.slots[0].state == .browserFrozen)
        #expect(afterQuit.slots[0].title == "Tab A")
    }

    @Test func ghostExpiryEvictsOldGhosts() {
        let slot = OrderedTabSlot(
            url: "https://old.com",
            title: "Old Ghost",
            browserName: "Google Chrome",
            state: .ghost,
            ghostedAt: Date().addingTimeInterval(-8 * 86400), // 8 days ago
            isPinned: true
        )

        let reconciled = MyOrderReconciler.reconcile(
            currentSlots: [slot],
            liveTabs: [],
            runningBrowsers: ["Google Chrome"],
            pendingCloses: [],
            now: Date(),
            ghostExpiryDays: 7
        )

        #expect(reconciled.slots.isEmpty)

        // If ghostExpiryDays is 0 (never), it survives
        let reconciledNever = MyOrderReconciler.reconcile(
            currentSlots: [slot],
            liveTabs: [],
            runningBrowsers: ["Google Chrome"],
            pendingCloses: [],
            now: Date(),
            ghostExpiryDays: 0
        )
        #expect(reconciledNever.slots.count == 1)
    }

    @Test func findMatchingLiveTabHelperMatchesNormalizedURL() {
        let liveTabs = [
            makeTab(title: "Docs", url: "https://example.com/docs/", browser: "Google Chrome"),
            makeTab(title: "Home", url: "https://other.com", browser: "Safari")
        ]

        let matched = MyOrderReconciler.findMatchingLiveTab(
            url: "https://example.com/docs",
            browserName: "Google Chrome",
            in: liveTabs
        )
        #expect(matched?.title == "Docs")

        let unmatched = MyOrderReconciler.findMatchingLiveTab(
            url: "https://missing.com",
            in: liveTabs
        )
        #expect(unmatched == nil)
    }

    @Test func ghostRevivesAsPinnedEvenIfBrowserReportsUnpinned() {
        let tabA = makeTab(title: "Tab A", url: "https://a.com", tabID: 101, isPinned: true)
        let tabB = makeTab(title: "Tab B", url: "https://b.com", tabID: 102, isPinned: false)

        let initial = MyOrderReconciler.reconcile(
            currentSlots: [],
            liveTabs: [tabA, tabB],
            runningBrowsers: ["Google Chrome"],
            pendingCloses: []
        )
        #expect(initial.slots.map(\.title) == ["Tab A", "Tab B"])

        // Close Tab A -> turns into ghost
        let afterClose = MyOrderReconciler.reconcile(
            currentSlots: initial.slots,
            liveTabs: [tabB],
            runningBrowsers: ["Google Chrome"],
            pendingCloses: []
        )
        #expect(afterClose.slots[0].state == .ghost)
        #expect(afterClose.slots[0].isPinned == true)

        // Tab A is reopened in Chrome, but Chrome opens it as unpinned! (isPinned: false)
        let tabAReopenedUnpinned = makeTab(title: "Tab A", url: "https://a.com", tabID: 105, isPinned: false)
        let afterReopen = MyOrderReconciler.reconcile(
            currentSlots: afterClose.slots,
            liveTabs: [tabB, tabAReopenedUnpinned],
            runningBrowsers: ["Google Chrome"],
            pendingCloses: []
        )

        // Slot must revive as live, stay pinned, and remain at the top of the list!
        #expect(afterReopen.slots.count == 2)
        #expect(afterReopen.slots[0].title == "Tab A")
        #expect(afterReopen.slots[0].state == .live)
        #expect(afterReopen.slots[0].isPinned == true)
        #expect(afterReopen.slots[1].title == "Tab B")
        #expect(afterReopen.slots[1].isPinned == false)
    }

    @Test func ghostRevivesWhenURLHasTrailingSlashVariant() {
        let ghostSlot = OrderedTabSlot(
            url: "https://example.com/",
            title: "Example",
            browserName: "Google Chrome",
            state: .ghost,
            ghostedAt: Date(),
            isPinned: true
        )

        // Browser reports live tab with no trailing slash
        let liveTab = makeTab(title: "Example", url: "https://example.com", tabID: 301, isPinned: false)
        let result = MyOrderReconciler.reconcile(
            currentSlots: [ghostSlot],
            liveTabs: [liveTab],
            runningBrowsers: ["Google Chrome"],
            pendingCloses: []
        )

        #expect(result.slots.count == 1)
        #expect(result.slots[0].state == .live)
        #expect(result.slots[0].isPinned == true)
        #expect(result.slots[0].boundTabID == 301)
    }

    @Test func ghostRevivesWhenURLRedirectsHttpToHttps() {
        let ghostSlot = OrderedTabSlot(
            url: "http://example.com",
            title: "Example",
            browserName: "Google Chrome",
            state: .ghost,
            ghostedAt: Date(),
            isPinned: true
        )

        // Browser reports live tab that redirected to https
        let liveTab = makeTab(title: "Example", url: "https://example.com", tabID: 302, isPinned: false)
        let result = MyOrderReconciler.reconcile(
            currentSlots: [ghostSlot],
            liveTabs: [liveTab],
            runningBrowsers: ["Google Chrome"],
            pendingCloses: []
        )

        #expect(result.slots.count == 1)
        #expect(result.slots[0].state == .live)
        #expect(result.slots[0].isPinned == true)
        #expect(result.slots[0].boundTabID == 302)
    }

    @Test func nonExtensionBrowserPreservesPinnedSlotsOnPoll() {
        // Tab from Safari (tabID is nil, isPinned is false)
        let safariTab = makeTab(title: "Apple", url: "https://apple.com", browser: "Safari", tabID: nil, isPinned: false)

        // Current slot in MyOrder was pinned by the user
        let pinnedSlot = OrderedTabSlot(
            url: "https://apple.com",
            title: "Apple",
            browserName: "Safari",
            state: .live,
            isPinned: true
        )

        let result = MyOrderReconciler.reconcile(
            currentSlots: [pinnedSlot],
            liveTabs: [safariTab],
            runningBrowsers: ["Safari"],
            pendingCloses: []
        )

        #expect(result.slots.count == 1)
        #expect(result.slots[0].state == .live)
        #expect(result.slots[0].isPinned == true)
    }

    @Test func pendingSlotClosePreventsGhostRevivalWhenTabStillPresentInLiveTabs() {
        let slotID = UUID()
        let ghostSlot = OrderedTabSlot(
            slotID: slotID,
            url: "https://notion.so/ux-consolidated",
            matchKey: "notion.so/ux-consolidated",
            title: "UX Notion",
            browserName: "Microsoft Edge",
            state: .ghost,
            boundTabID: nil,
            ghostedAt: Date(),
            isPinned: true
        )

        // Browser tab hasn't closed yet or is a phantom/stale tab in snapshot
        let lingeringTab = makeTab(
            title: "UX Notion",
            url: "https://notion.so/ux-consolidated",
            browser: "Microsoft Edge",
            tabID: 484802241,
            isPinned: true
        )

        // PendingSlotClose is active for this slot
        let pending = [PendingSlotClose(
            slotID: slotID,
            browserName: "Microsoft Edge",
            url: "https://notion.so/ux-consolidated",
            tabID: 484802241,
            createdAt: Date()
        )]

        let result = MyOrderReconciler.reconcile(
            currentSlots: [ghostSlot],
            liveTabs: [lingeringTab],
            runningBrowsers: ["Microsoft Edge"],
            pendingCloses: pending
        )

        // Must stay a ghost! Do NOT revive to live while pending close is active!
        #expect(result.slots.count == 1)
        #expect(result.slots[0].state == .ghost)
        // And the pending close must still be preserved or tracked
        #expect(!result.remainingPendingCloses.isEmpty)
    }

    @Test func reconcileDeduplicatesMultiplePinnedSlotsForSameCanonicalURL() {
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

        // Only 1 actual live tab in the browser (or 0)
        let liveTab = makeTab(
            title: "UX Notion",
            url: notionURL,
            browser: "Microsoft Edge",
            tabID: 484802241,
            isPinned: true
        )

        let result = MyOrderReconciler.reconcile(
            currentSlots: [slot1, slot2],
            liveTabs: [liveTab],
            runningBrowsers: ["Microsoft Edge"],
            pendingCloses: []
        )

        // Only 1 slot must remain!
        #expect(result.slots.count == 1)
        #expect(result.slots[0].state == .live)
        #expect(result.slots[0].isPinned == true)
    }


    @Test func deduplicatePinnedSlotsCollapsesHttpAndHttpsVariants() {
        let slot1 = OrderedTabSlot(
            slotID: UUID(),
            url: "http://example.com/page",
            title: "Example",
            browserName: "Google Chrome",
            state: .live,
            isPinned: true
        )
        let slot2 = OrderedTabSlot(
            slotID: UUID(),
            url: "https://example.com/page",
            title: "Example",
            browserName: "Google Chrome",
            state: .ghost,
            isPinned: true
        )

        let deduped = MyOrderReconciler.deduplicatePinnedSlots([slot1, slot2])
        #expect(deduped.count == 1)
        #expect(deduped[0].state == .live)
    }

    @Test func pendingSlotCloseWithTabIDPreventsGhostRevivalWhenAppleScriptReturnsNilTabID() {
        let slotID = UUID()
        let ghostSlot = OrderedTabSlot(
            slotID: slotID,
            url: "https://notion.so/ux-consolidated",
            matchKey: "notion.so/ux-consolidated",
            title: "UX Notion",
            browserName: "Microsoft Edge",
            state: .ghost,
            boundTabID: nil,
            ghostedAt: Date(),
            isPinned: true
        )

        // AppleScript live tab has tabID == nil
        let appleScriptTab = makeTab(
            title: "UX Notion",
            url: "https://notion.so/ux-consolidated",
            browser: "Microsoft Edge",
            tabID: nil,
            isPinned: false
        )

        // PendingSlotClose has the extension tabID
        let pending = [PendingSlotClose(
            slotID: slotID,
            browserName: "Microsoft Edge",
            url: "https://notion.so/ux-consolidated",
            tabID: 484802241,
            createdAt: Date()
        )]

        let result = MyOrderReconciler.reconcile(
            currentSlots: [ghostSlot],
            liveTabs: [appleScriptTab],
            runningBrowsers: ["Microsoft Edge"],
            pendingCloses: pending
        )

        // Must stay a ghost! Do NOT revive to live while pending close is active!
        #expect(result.slots.count == 1)
        #expect(result.slots[0].state == .ghost)
    }

    @Test func pendingCloseIsConsumedOnceGhostTabIsAbsentFromLiveTabs() {
        let slotID = UUID()
        let ghostSlot = OrderedTabSlot(
            slotID: slotID,
            url: "https://notion.so/ux-consolidated",
            matchKey: "notion.so/ux-consolidated",
            title: "UX Notion",
            browserName: "Microsoft Edge",
            state: .ghost,
            boundTabID: nil,
            ghostedAt: Date(),
            isPinned: true
        )

        let pending = [PendingSlotClose(
            slotID: slotID,
            browserName: "Microsoft Edge",
            url: "https://notion.so/ux-consolidated",
            tabID: 484802241,
            createdAt: Date()
        )]

        // Reconcile with 0 live tabs (tab has disappeared from browser)
        let step1 = MyOrderReconciler.reconcile(
            currentSlots: [ghostSlot],
            liveTabs: [],
            runningBrowsers: ["Microsoft Edge"],
            pendingCloses: pending
        )

        // Pending close must be consumed!
        #expect(step1.remainingPendingCloses.isEmpty)

        // If user subsequently reopens that URL in the browser, it can revive cleanly
        let reopenedTab = makeTab(
            title: "UX Notion",
            url: "https://notion.so/ux-consolidated",
            browser: "Microsoft Edge",
            tabID: 484803000,
            isPinned: false
        )
        let step2 = MyOrderReconciler.reconcile(
            currentSlots: step1.slots,
            liveTabs: [reopenedTab],
            runningBrowsers: ["Microsoft Edge"],
            pendingCloses: step1.remainingPendingCloses
        )

        #expect(step2.slots.count == 1)
        #expect(step2.slots[0].state == .live)
        #expect(step2.slots[0].boundTabID == 484803000)
    }

    @Test func unpinnedDuplicateTabsInDifferentWindowsArePreserved() {
        let tabWin1 = makeTab(title: "Doc", url: "https://docs.google.com/1", tabID: 101, win: 1, tabIndex: 1, isPinned: false)
        let tabWin2 = makeTab(title: "Doc", url: "https://docs.google.com/1", tabID: 102, win: 2, tabIndex: 1, isPinned: false)

        let result = MyOrderReconciler.reconcile(
            currentSlots: [],
            liveTabs: [tabWin1, tabWin2],
            runningBrowsers: ["Google Chrome"],
            pendingCloses: []
        )

        // Both unpinned duplicate tabs in different windows MUST be preserved!
        #expect(result.slots.count == 2)
        #expect(result.slots[0].boundTabID == 101)
        #expect(result.slots[1].boundTabID == 102)
    }

    @Test func ghostTabInLiveTabsInputDoesNotReviveGhostSlot() {
        let ghostSlot = OrderedTabSlot(
            url: "https://example.com/pinned",
            title: "Pinned Tab",
            browserName: "Google Chrome",
            state: .ghost,
            ghostedAt: Date(),
            isPinned: true
        )

        let ghostTabResult = BrowserSearchResult(
            title: "Pinned Tab",
            url: "https://example.com/pinned",
            browserName: "Google Chrome",
            type: .tab,
            timestamp: Date(),
            isPinned: true,
            isGhost: true
        )

        let result = MyOrderReconciler.reconcile(
            currentSlots: [ghostSlot],
            liveTabs: [ghostTabResult],
            runningBrowsers: ["Google Chrome"],
            pendingCloses: []
        )

        #expect(result.slots.count == 1)
        #expect(result.slots[0].state == .ghost)
    }

    @Test func duplicateSlotsWithSameBoundTabIDCollapseToSingleSlot() {
        let oldSlot = OrderedTabSlot(
            slotID: UUID(),
            url: "http://127.0.0.1:18789/chat/main/b07ae87c",
            title: "Chat",
            browserName: "Microsoft Edge",
            boundTabID: 484804868
        )
        let dupSlot = OrderedTabSlot(
            slotID: UUID(),
            url: "http://127.0.0.1:18789/chat/main/b07ae87c",
            title: "Chat",
            browserName: "Microsoft Edge",
            boundTabID: 484804868
        )

        let deduped = MyOrderReconciler.deduplicateSlots([oldSlot, dupSlot])
        #expect(deduped.count == 1)
        #expect(deduped[0].boundTabID == 484804868)
    }

    @Test func unpinnedTabDoesNotDuplicateAlreadyPinnedCanonicalURLInSameWindow() {
        let pinnedNotion = makeTab(
            title: "(9+) Engineering AI Adoption",
            url: "https://app.notion.com/p/sevensystem/Engineering-AI-Adoption?t=38212269734a8069a48600a96b155008",
            tabID: 484801772,
            win: 1,
            tabIndex: 2,
            isPinned: true
        )
        let unpinnedNotion = makeTab(
            title: "Engineering AI Adoption",
            url: "https://app.notion.com/p/sevensystem/Engineering-AI-Adoption?t=3d912269734a80fd948400a98fb66b1c",
            tabID: 484803020,
            win: 1,
            tabIndex: 13,
            isPinned: false
        )

        let result = MyOrderReconciler.reconcile(
            currentSlots: [],
            liveTabs: [pinnedNotion, unpinnedNotion],
            runningBrowsers: ["Microsoft Edge"],
            pendingCloses: []
        )

        #expect(result.slots.count == 1)
        #expect(result.slots[0].isPinned == true)
    }

    @Test func duplicateUnpinnedSlotsInSameWindowCollapseEvenWithDifferentTabIDs() {
        let oldSlot = OrderedTabSlot(
            slotID: UUID(),
            url: "http://127.0.0.1:18789/chat/main/b07ae87c",
            title: "send my youtube tabs to feed — OpenClaw",
            browserName: "Microsoft Edge",
            boundTabID: 484803551,
            windowIndex: 1,
            tabIndex: 34
        )
        let newSlot = OrderedTabSlot(
            slotID: UUID(),
            url: "http://127.0.0.1:18789/chat/main/b07ae87c",
            title: "send my youtube tabs to feed — OpenClaw",
            browserName: "Microsoft Edge",
            boundTabID: 484804868,
            windowIndex: 1,
            tabIndex: 28
        )

        let deduped = MyOrderReconciler.deduplicateSlots([oldSlot, newSlot])
        #expect(deduped.count == 1, "Duplicate unpinned slots for the same URL in the same window must collapse even if tabIDs differ")
        #expect(deduped[0].boundTabID == 484804868)
    }

    @Test func reconcileCollapsesDuplicateUnpinnedSlotsWhenOnlyOneTabLive() {
        let oldSlot = OrderedTabSlot(
            slotID: UUID(),
            url: "http://127.0.0.1:18789/chat/main/b07ae87c",
            title: "send my youtube tabs to feed — OpenClaw",
            browserName: "Microsoft Edge",
            boundTabID: 484803551,
            windowIndex: 1,
            tabIndex: 34
        )
        let newSlot = OrderedTabSlot(
            slotID: UUID(),
            url: "http://127.0.0.1:18789/chat/main/b07ae87c",
            title: "send my youtube tabs to feed — OpenClaw",
            browserName: "Microsoft Edge",
            boundTabID: 484804868,
            windowIndex: 1,
            tabIndex: 28
        )

        let liveTab = makeTab(
            title: "send my youtube tabs to feed — OpenClaw",
            url: "http://127.0.0.1:18789/chat/main/b07ae87c",
            browser: "Microsoft Edge",
            tabID: 484804868,
            win: 1,
            tabIndex: 28,
            isPinned: false
        )

        let result = MyOrderReconciler.reconcile(
            currentSlots: [oldSlot, newSlot],
            liveTabs: [liveTab],
            runningBrowsers: ["Microsoft Edge"],
            pendingCloses: []
        )

        #expect(result.slots.count == 1, "Only 1 slot must survive when browser has 1 tab")
        #expect(result.slots[0].boundTabID == 484804868)
    }
}


