import Foundation
import Testing
@testable import FastTab

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
