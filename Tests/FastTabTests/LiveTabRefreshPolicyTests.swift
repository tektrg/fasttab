import Foundation
import CloudKit
import Testing
@testable import FastTab
import FastTabSync

struct LiveTabRefreshPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func tab(_ title: String, browser: String) -> BrowserSearchResult {
        BrowserSearchResult(
            title: title,
            url: "https://\(title).example",
            browserName: browser,
            type: .tab,
            timestamp: Date(),
            windowIndex: 1,
            tabIndex: 1
        )
    }

    // MARK: - Failed read vs zero tabs

    @Test func timedOutOrFailedScriptIsUnreadable() {
        #expect(LiveTabScriptOutput(rawOutput: nil) == .unreadable)
        #expect(LiveTabScriptOutput(rawOutput: kLiveTabReadFailedSentinel) == .unreadable)
    }

    @Test func browserNotRunningIsGenuinelyEmpty() {
        #expect(LiveTabScriptOutput(rawOutput: "") == .noTabs)
        #expect(LiveTabScriptOutput(rawOutput: "row") == .rows("row"))
    }

    @Test func unreadableBrowserKeepsItsPreviousTabs() {
        let previous = [tab("chrome-old", browser: "Google Chrome"), tab("safari-old", browser: "Safari")]
        let fetched = [tab("safari-new", browser: "Safari")]
        let merged = LiveTabRefreshPolicy.carryingForwardUnreadableBrowsers(
            fetched: fetched,
            unreadableBrowsers: ["Google Chrome"],
            previous: previous
        )
        #expect(Set(merged.map(\.title)) == ["safari-new", "chrome-old"])
    }

    @Test func readableEmptyBrowserIsNotCarriedForward() {
        // Chrome quit (read succeeded with zero tabs): its tabs must go.
        let previous = [tab("chrome-old", browser: "Google Chrome")]
        let merged = LiveTabRefreshPolicy.carryingForwardUnreadableBrowsers(
            fetched: [],
            unreadableBrowsers: [],
            previous: previous
        )
        #expect(merged.isEmpty)
    }

    @Test func unreadableBrowserWithNoHistoryStaysEmpty() {
        let merged = LiveTabRefreshPolicy.carryingForwardUnreadableBrowsers(
            fetched: [tab("safari", browser: "Safari")],
            unreadableBrowsers: ["Google Chrome"],
            previous: []
        )
        #expect(merged.map(\.title) == ["safari"])
    }

    // MARK: - Extension-event throttle

    @Test func firstExtensionEventWaitsOnlyTheCoalesceDelay() {
        #expect(LiveTabRefreshPolicy.extensionEventRefreshDelay(lastRefreshStartedAt: nil, now: now)
            == LiveTabRefreshPolicy.extensionEventCoalesceDelay)
        let longAgo = now.addingTimeInterval(-600)
        #expect(LiveTabRefreshPolicy.extensionEventRefreshDelay(lastRefreshStartedAt: longAgo, now: now)
            == LiveTabRefreshPolicy.extensionEventCoalesceDelay)
    }

    @Test func extensionEventSoonAfterRefreshWaitsOutTheThrottle() {
        let justNow = now.addingTimeInterval(-1)
        let delay = LiveTabRefreshPolicy.extensionEventRefreshDelay(lastRefreshStartedAt: justNow, now: now)
        #expect(delay == LiveTabRefreshPolicy.extensionEventMinimumInterval - 1)
    }

    // MARK: - Which extension events refresh fast

    private func extensionTab(_ tabID: Int, url: String, browser: String = "Google Chrome") -> BrowserSearchResult {
        BrowserSearchResult(
            title: "t\(tabID)",
            url: url,
            browserName: browser,
            type: .tab,
            timestamp: Date(),
            windowIndex: 1,
            tabIndex: tabID,
            tabID: tabID
        )
    }

    @Test func tabSwitchOrTitleUpsertRidesTheIdleRefresh() {
        let cached = [extensionTab(1, url: "https://a.example")]
        #expect(!LiveTabRefreshPolicy.upsertChangesPhoneTabList(
            cachedTabs: cached, browserName: "Google Chrome", tabID: 1, url: "https://a.example"))
    }

    @Test func newTabOrNavigationUpsertRefreshesFast() {
        let cached = [extensionTab(1, url: "https://a.example")]
        #expect(LiveTabRefreshPolicy.upsertChangesPhoneTabList(
            cachedTabs: cached, browserName: "Google Chrome", tabID: 2, url: "https://b.example"))
        #expect(LiveTabRefreshPolicy.upsertChangesPhoneTabList(
            cachedTabs: cached, browserName: "Google Chrome", tabID: 1, url: "https://moved.example"))
        // Same tab ID in another browser is a different tab.
        #expect(LiveTabRefreshPolicy.upsertChangesPhoneTabList(
            cachedTabs: cached, browserName: "Arc", tabID: 1, url: "https://a.example"))
    }

    @Test func focusChangeSnapshotWithKnownTabsRidesTheIdleRefresh() {
        let cached = [extensionTab(1, url: "https://a.example"), extensionTab(2, url: "https://b.example")]
        #expect(!LiveTabRefreshPolicy.snapshotChangesPhoneTabList(
            cachedTabs: cached, browserName: "Google Chrome", snapshotTabIDs: [2, 1]))
        // One profile's snapshot (a subset) is not a change either.
        #expect(!LiveTabRefreshPolicy.snapshotChangesPhoneTabList(
            cachedTabs: cached, browserName: "Google Chrome", snapshotTabIDs: [1]))
    }

    @Test func snapshotWithUnseenTabRefreshesFast() {
        let cached = [extensionTab(1, url: "https://a.example"), extensionTab(9, url: "https://z.example", browser: "Arc")]
        #expect(LiveTabRefreshPolicy.snapshotChangesPhoneTabList(
            cachedTabs: cached, browserName: "Google Chrome", snapshotTabIDs: [1, 9]))
    }

    @Test func pendingExtensionRefreshSkipsWhenANewerRefreshStarted() {
        let eventAt = now
        #expect(LiveTabRefreshPolicy.shouldRunPendingExtensionEventRefresh(latestEventAt: eventAt, lastRefreshStartedAt: nil))
        // Refresh started before the event: it may have read the old state.
        #expect(LiveTabRefreshPolicy.shouldRunPendingExtensionEventRefresh(
            latestEventAt: eventAt, lastRefreshStartedAt: eventAt.addingTimeInterval(-1)))
        // Idle/other refresh started after the event already covers it.
        #expect(!LiveTabRefreshPolicy.shouldRunPendingExtensionEventRefresh(
            latestEventAt: eventAt, lastRefreshStartedAt: eventAt.addingTimeInterval(1)))
    }

    // MARK: - Publish spares unreadable browsers

    private func recordID(_ name: String) -> CKRecord.ID {
        CKRecord.ID(recordName: name, zoneID: SyncConstants.stateZoneID)
    }

    @Test func publishNeverDeletesRecordsOfAnUnreadableBrowser() {
        // First read after launch: Chrome unreadable, nothing to carry forward.
        let chromeTab = recordID(SyncService.tabRecordName(deviceID: "mac", browserName: "Google Chrome", windowIndex: 1, tabIndex: 1, tabID: 7, fallbackIndex: 0))
        let safariKept = recordID(SyncService.tabRecordName(deviceID: "mac", browserName: "Safari", windowIndex: 1, tabIndex: 1, tabID: nil, fallbackIndex: 0))
        let safariClosed = recordID(SyncService.tabRecordName(deviceID: "mac", browserName: "Safari", windowIndex: 1, tabIndex: 2, tabID: nil, fallbackIndex: 1))
        let toDelete = SyncService.tabRecordIDsToDelete(
            previouslyPublished: [chromeTab, safariKept, safariClosed],
            currentlyPublished: [safariKept],
            sparingBrowsers: ["Google Chrome"],
            deviceID: "mac"
        )
        #expect(toDelete == [safariClosed])
    }

    @Test func publishWithEverythingReadableDeletesAsBefore() {
        let chromeTab = recordID(SyncService.tabRecordName(deviceID: "mac", browserName: "Google Chrome", windowIndex: 1, tabIndex: 1, tabID: 7, fallbackIndex: 0))
        let toDelete = SyncService.tabRecordIDsToDelete(
            previouslyPublished: [chromeTab],
            currentlyPublished: [],
            sparingBrowsers: [],
            deviceID: "mac"
        )
        #expect(toDelete == [chromeTab])
    }

    @Test func reconcileNeverDeletesRecordsOfAnUnreadableOrAbsentBrowser() {
        // Present only via ghost pinned slots / carried tabs while unreadable.
        #expect(!SyncService.reconcileMayDeleteRecords(
            ofBrowser: "Google Chrome", snapshotBrowsers: ["Google Chrome", "Safari"], unreadableBrowsers: ["Google Chrome"]))
        #expect(!SyncService.reconcileMayDeleteRecords(
            ofBrowser: "Arc", snapshotBrowsers: ["Safari"], unreadableBrowsers: []))
        #expect(SyncService.reconcileMayDeleteRecords(
            ofBrowser: "Safari", snapshotBrowsers: ["Google Chrome", "Safari"], unreadableBrowsers: ["Google Chrome"]))
    }

    @Test func unreadableSetChangesThePublishFingerprint() {
        #expect(SyncService.unreadableBrowsersFingerprintSuffix([]) == "")
        #expect(SyncService.unreadableBrowsersFingerprintSuffix(["Safari", "Arc"])
            == SyncService.unreadableBrowsersFingerprintSuffix(["Arc", "Safari"]))
        #expect(SyncService.unreadableBrowsersFingerprintSuffix(["Safari"]) != "")
    }

    // MARK: - Idle refresh cadence

    @Test func idleRefreshRunsOnlyAfterTheInterval() {
        #expect(LiveTabRefreshPolicy.shouldRunIdleRefresh(lastRefreshStartedAt: nil, now: now))
        let recent = now.addingTimeInterval(-(LiveTabRefreshPolicy.idleRefreshInterval - 1))
        #expect(!LiveTabRefreshPolicy.shouldRunIdleRefresh(lastRefreshStartedAt: recent, now: now))
        let due = now.addingTimeInterval(-LiveTabRefreshPolicy.idleRefreshInterval)
        #expect(LiveTabRefreshPolicy.shouldRunIdleRefresh(lastRefreshStartedAt: due, now: now))
    }

    // MARK: - Reconcile freshness

    @Test func reconcileTrustsOnlyHydratedRecentSnapshots() {
        #expect(!LiveTabRefreshPolicy.isSnapshotFreshForReconcile(isHydrated: false, lastFetchedAt: now, now: now, maxAge: 60))
        #expect(!LiveTabRefreshPolicy.isSnapshotFreshForReconcile(isHydrated: true, lastFetchedAt: nil, now: now, maxAge: 60))
        #expect(!LiveTabRefreshPolicy.isSnapshotFreshForReconcile(isHydrated: true, lastFetchedAt: now.addingTimeInterval(-60), now: now, maxAge: 60))
        #expect(LiveTabRefreshPolicy.isSnapshotFreshForReconcile(isHydrated: true, lastFetchedAt: now.addingTimeInterval(-59), now: now, maxAge: 60))
    }
}
