import Foundation
import Testing
@testable import FastTab
import FastTabSync

/// "Layer 1" end-to-end scenarios for the core promise: a tab closed on the
/// Mac disappears from the iPhone.
///
/// **What runs for real:** `LiveTabRefreshPipeline` (idle cadence, extension
/// event coalesce/throttle, carry-forward of unreadable reads, authoritative
/// snapshot), `LiveTabReader` (parallel backend read), and
/// `LiveTabPublishState` (fingerprint skip, save/delete diff against the
/// persisted ledger, delete acks, state-zone reconcile). Production
/// `BrowserTabService` / `SyncService` delegate to these same types.
///
/// **What is faked** (`LiveTabSyncHarness.swift`): browsers
/// (`FakeBrowserBackend`: scriptable tabs, unreadable, not running, extension
/// vs AppleScript naming), time (`SimulatedClock`, no real sleeps), and
/// CloudKit (`FakeStateZone`, records keyed by record name; CKSyncEngine
/// transport is assumed to deliver what it is given unless a scenario loses it).
/// Not covered: CKSyncEngine retry/conflict handling, publish coalescing in
/// `SyncService.requestLiveTabsPublish`, command-bar UI state.
///
/// **Adding a scenario:** build browsers with `FakeBrowserBackend(_:tabs:servesTabIDs:)`,
/// `await harness.launch()`, change the browser (`closeTab`, `quit`,
/// `readBehavior`, `servesTabIDs`) or send an extension event
/// (`harness.extensionTabRemoved` …), then `await harness.advance(by:)` /
/// `secondsUntilServerMatchesOpenTabs(within:)` and assert on
/// `harness.serverTabs` / `harness.zone`. Keep bounds to the product promise
/// (idle ≤ ~70s, extension ≤ ~6s), not to implementation timings.
@MainActor
@Suite(.serialized)
struct LiveTabSyncScenarioTests {
    private func chrome(_ tabs: [FakeTab], extension servesTabIDs: Bool = false) -> FakeBrowserBackend {
        FakeBrowserBackend("Google Chrome", tabs: tabs, servesTabIDs: servesTabIDs)
    }

    private func safari(_ tabs: [FakeTab]) -> FakeBrowserBackend {
        FakeBrowserBackend("Safari", tabs: tabs, servesTabIDs: false)
    }

    private let threeTabs: [FakeTab] = [.page("alpha", id: 11), .page("beta", id: 12), .page("gamma", id: 13)]

    private func launched(_ browsers: FakeBrowserBackend...) async -> LiveTabSyncHarness {
        let harness = LiveTabSyncHarness(browsers)
        await harness.launch()
        #expect(harness.serverMatchesOpenTabs, "launch publish:\n\(harness.serverDescription)")
        return harness
    }

    // MARK: 1–2. Close reaches the phone while FastTab is idle

    @Test func idleCloseInAppleScriptBrowserLeavesServerWithin70Seconds() async {
        let browser = chrome(threeTabs)
        let harness = await launched(browser)
        await harness.advance(by: 5)

        browser.closeTab(url: FakeTab.page("alpha", id: 11).url)

        let seconds = await harness.secondsUntilServerMatchesOpenTabs(within: 70)
        #expect(seconds != nil, "closed tab still on server after 70s:\n\(harness.serverDescription)")
        #expect(harness.serverTabs.count == 2)
    }

    @Test func idleCloseViaExtensionEventLeavesServerWithin6Seconds() async {
        let browser = chrome(threeTabs, extension: true)
        let harness = await launched(browser)
        await harness.advance(by: 30)

        harness.extensionTabRemoved(browser, url: FakeTab.page("beta", id: 12).url)

        let seconds = await harness.secondsUntilServerMatchesOpenTabs(within: 6)
        #expect(seconds != nil, "closed tab still on server after 6s:\n\(harness.serverDescription)")
    }

    @Test func extensionCloseRightAfterARefreshIsThrottledButStillWithin6Seconds() async {
        let browser = chrome(threeTabs, extension: true)
        let harness = await launched(browser)
        await harness.advance(by: 1) // launch refresh started 1s ago

        harness.extensionTabRemoved(browser, url: FakeTab.page("beta", id: 12).url)

        let seconds = await harness.secondsUntilServerMatchesOpenTabs(within: 6)
        #expect(seconds != nil, "\(harness.serverDescription)")
        // Throttle: no sooner than 5s after the previous refresh started.
        #expect((seconds ?? 0) >= LiveTabRefreshPolicy.extensionEventMinimumInterval - 1, "throttle bypassed")
    }

    @Test func closingAWindowBurstBecomesOneRefresh() async {
        let tabs = (1...6).map { FakeTab.page("tab\($0)", id: $0, window: 2) } + [FakeTab.page("keep", id: 99)]
        let browser = chrome(tabs, extension: true)
        let harness = await launched(browser)
        await harness.advance(by: 30)
        let readsBefore = browser.readCount

        for tab in tabs.dropLast() { harness.extensionTabRemoved(browser, url: tab.url) }

        let seconds = await harness.secondsUntilServerMatchesOpenTabs(within: 6)
        #expect(seconds != nil)
        #expect(browser.readCount - readsBefore == 1, "burst of 6 closes should coalesce into one read")
    }

    // MARK: 3. Browser quit

    @Test func quittingABrowserDeletesAllItsRecords() async {
        let chromeBrowser = chrome(threeTabs)
        let safariBrowser = safari([.page("delta", id: 21)])
        let harness = await launched(chromeBrowser, safariBrowser)

        chromeBrowser.quit()

        let seconds = await harness.secondsUntilServerMatchesOpenTabs(within: 70)
        #expect(seconds != nil, "\(harness.serverDescription)")
        #expect(harness.serverTabs(of: chromeBrowser).isEmpty)
        #expect(harness.serverTabs(of: safariBrowser).count == 1)
    }

    // MARK: 4–5. A failed read is never "zero tabs"

    @Test func readTimeoutMidSessionKeepsRecordsThenRecovers() async {
        let browser = chrome(threeTabs)
        let harness = await launched(browser)
        let recordsBefore = Set(harness.serverTabs.map(\.id))
        let deletesBefore = harness.zone.deleteCount

        browser.readBehavior = .unreadable
        browser.closeTab(url: FakeTab.page("gamma", id: 13).url)
        await harness.advance(by: 200) // three idle refreshes + nothing else

        #expect(harness.zone.deleteCount == deletesBefore, "an unreadable read must not delete anything")
        #expect(Set(harness.serverTabs.map(\.id)) == recordsBefore)

        browser.readBehavior = .readable
        let seconds = await harness.secondsUntilServerMatchesOpenTabs(within: 70)
        #expect(seconds != nil, "did not recover:\n\(harness.serverDescription)")
    }

    @Test func unreadableFirstRefreshAfterRelaunchKeepsPersistedRecords() async {
        let browser = chrome(threeTabs)
        let harness = await launched(browser)
        let recordsBefore = Set(harness.serverTabs.map(\.id))
        let deletesBefore = harness.zone.deleteCount

        browser.readBehavior = .unreadable
        await harness.relaunch() // empty snapshot, nothing to carry forward
        await harness.advance(by: 200) // startup reconcile retries + idle refreshes

        #expect(harness.zone.deleteCount == deletesBefore, "relaunch with an unreadable browser deleted records")
        #expect(Set(harness.serverTabs.map(\.id)) == recordsBefore)

        browser.closeTab(url: FakeTab.page("alpha", id: 11).url)
        browser.readBehavior = .readable
        let seconds = await harness.secondsUntilServerMatchesOpenTabs(within: 70)
        #expect(seconds != nil, "persisted ledger did not drive the delete after recovery:\n\(harness.serverDescription)")
    }

    @Test func oneUnreadableBrowserDoesNotBlockAnotherBrowsersClose() async {
        let chromeBrowser = chrome(threeTabs)
        let safariBrowser = safari([.page("delta", id: 21), .page("epsilon", id: 22)])
        let harness = await launched(chromeBrowser, safariBrowser)
        let chromeRecords = Set(harness.serverTabs(of: chromeBrowser).map(\.id))

        chromeBrowser.readBehavior = .unreadable
        safariBrowser.closeTab(url: FakeTab.page("delta", id: 21).url)
        await harness.advance(by: 70)

        #expect(harness.serverTabs(of: safariBrowser).map(\.url) == [FakeTab.page("epsilon", id: 22).url])
        #expect(Set(harness.serverTabs(of: chromeBrowser).map(\.id)) == chromeRecords)
    }

    // MARK: 6. Reconcile sweep

    @Test func orphanRecordUnknownToLedgerIsRemovedByStartupReconcile() async {
        let browser = chrome(threeTabs)
        let harness = LiveTabSyncHarness([browser])
        harness.zone.seedStrandedRecord(SyncedTab(
            id: SyncService.tabRecordName(
                deviceID: LiveTabSyncHarness.deviceID, browserName: browser.appName,
                windowIndex: 9, tabIndex: 9, tabID: nil, fallbackIndex: 0
            ),
            deviceID: LiveTabSyncHarness.deviceID,
            browserName: browser.appName,
            title: "Closed long ago",
            url: "https://stale.example/"
        ))

        await harness.launch()
        let seconds = await harness.secondsUntilServerMatchesOpenTabs(within: 10)

        #expect(seconds != nil, "orphan survived startup reconcile:\n\(harness.serverDescription)")
        #expect(harness.reconcileRunCount >= 1)
    }

    @Test func lostDeleteConvergesViaPeriodicReconcile() async {
        let browser = chrome(threeTabs)
        let harness = await launched(browser)
        harness.zone.deletesToLose = 1

        browser.closeTab(url: FakeTab.page("gamma", id: 13).url)
        await harness.advance(by: 70)
        #expect(!harness.serverMatchesOpenTabs, "precondition: the delete was lost")

        let seconds = await harness.secondsUntilServerMatchesOpenTabs(within: SyncService.tabReconcileInterval)
        #expect(seconds != nil, "lost delete never converged:\n\(harness.serverDescription)")
    }

    // MARK: 7–8. Quiet when nothing the phone shows changed

    @Test func noChangesMeansZeroServerWritesAcrossManyTicks() async {
        let browser = chrome(threeTabs)
        let harness = await launched(browser)
        await harness.advance(by: 10)
        let writesBefore = harness.zone.writeCount
        let readsBefore = browser.readCount

        await harness.advance(by: 30 * 60)

        #expect(harness.zone.writeCount == writesBefore)
        #expect(browser.readCount - readsBefore >= 25, "idle refresh should keep reading (~1/min)")
    }

    @Test func tabSwitchAndTitleOnlyEventsRideTheIdleCadence() async {
        let browser = chrome(threeTabs, extension: true)
        let harness = await launched(browser)
        await harness.advance(by: 30)
        let readsBefore = browser.readCount

        var retitled = FakeTab.page("alpha", id: 11)
        retitled.title = "Alpha (3 unread)"
        harness.extensionTabUpserted(browser, tab: retitled) // title only
        harness.extensionSnapshot(browser) // focus change, no new tab IDs
        await harness.advance(by: 6)

        #expect(browser.readCount == readsBefore, "title/focus events must not trigger a fast refresh")

        let seconds = await harness.secondsUntilServerMatchesOpenTabs(within: 70)
        #expect(seconds != nil, "title change never reached the server via the idle refresh")
    }

    @Test func navigationAndNewTabEventsDoTriggerAFastRefresh() async {
        let browser = chrome(threeTabs, extension: true)
        let harness = await launched(browser)
        await harness.advance(by: 30)

        harness.extensionTabUpserted(browser, tab: FakeTab(url: "https://navigated.example/", title: "Navigated", tabID: 11))
        harness.extensionTabUpserted(browser, tab: .page("fresh", id: 14))

        let seconds = await harness.secondsUntilServerMatchesOpenTabs(within: 6)
        #expect(seconds != nil, "\(harness.serverDescription)")
    }

    // MARK: 9. Naming-scheme flip

    @Test func extensionAppleScriptSchemeFlipLeavesNoDuplicates() async {
        let browser = chrome(threeTabs, extension: true)
        let harness = await launched(browser)
        #expect(harness.serverTabs.allSatisfy { $0.id.contains("_tab_") })

        browser.servesTabIDs = false // extension dropped: positional names
        #expect(await harness.secondsUntilServerMatchesOpenTabs(within: 70) != nil)
        await harness.advance(by: 70)
        #expect(harness.serverTabs.allSatisfy { $0.id.contains("_win1_idx") }, "\(harness.serverDescription)")
        #expect(harness.serverTabs.count == 3)

        browser.servesTabIDs = true
        browser.closeTab(url: FakeTab.page("beta", id: 12).url)
        await harness.advance(by: 70)
        #expect(harness.serverMatchesOpenTabs, "\(harness.serverDescription)")
        #expect(harness.serverTabs.allSatisfy { $0.id.contains("_tab_") }, "\(harness.serverDescription)")
    }

    // MARK: Slow reads

    @Test func steadyExtensionEventsDuringSlowReadsStillPublish() async {
        // Reads slower than the 5s extension throttle (osascript may take up
        // to its 8s timeout) must not be superseded by every new event, or
        // nothing ever reaches the phone while the user keeps browsing.
        let browser = chrome(threeTabs, extension: true)
        let harness = await launched(browser)
        await harness.advance(by: 30)
        harness.readDuration = 8

        for index in 1...15 { // a new tab every 3s for 45s
            harness.extensionTabUpserted(browser, tab: .page("new\(index)", id: 100 + index))
            await harness.advance(by: 3)
        }

        let newTabsOnServer = harness.serverTabs(of: browser).filter { $0.url.contains("://new") }.count
        #expect(newTabsOnServer >= 10, "reads starved by events; new tabs on server: \(newTabsOnServer)")
        #expect(await harness.secondsUntilServerMatchesOpenTabs(within: 20) != nil, "\(harness.serverDescription)")
    }

    // MARK: Extras

    @Test func privateWindowTabsNeverReachTheServer() async {
        var privateTab = FakeTab.page("secret", id: 50)
        privateTab.profileName = "Incognito"
        let browser = chrome(threeTabs + [privateTab])
        let harness = await launched(browser)

        #expect(!harness.serverTabs.contains { $0.url == privateTab.url })
    }

    @Test func tabClosedInAppleScriptBrowserShiftsPositionsWithoutStaleRecords() async {
        // Closing the first tab renames every later positional record
        // (idx2 → idx1 …): the old names must all be deleted.
        let browser = chrome((1...5).map { FakeTab.page("p\($0)", id: $0) })
        let harness = await launched(browser)

        browser.closeTab(url: FakeTab.page("p1", id: 1).url)

        #expect(await harness.secondsUntilServerMatchesOpenTabs(within: 70) != nil, "\(harness.serverDescription)")
        #expect(Set(harness.serverTabs.map(\.id)).count == 4)
    }
}
