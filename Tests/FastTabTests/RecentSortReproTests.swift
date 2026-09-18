import Foundation
import Testing
@testable import FastTab

@Suite("Recent Sort Repro Tests")
struct RecentSortReproTests {

    private final class MockBridge: ExtensionBridgeServing, @unchecked Sendable {
        var view: ExtensionSnapshotView?
        func snapshotView(for appName: String, profileCount: Int) -> ExtensionSnapshotView? { view }
        func isConnected(appName: String) -> Bool { view != nil }
        func sendCommand(appName: String, type: String, tabID: Int, extraPayload: [String: Any], timeout: TimeInterval) -> Bool { false }
    }

    private final class DummyBackend: BrowserBackend, @unchecked Sendable {
        var appName: String { "Microsoft Edge" }
        var bundleIdentifier: String { "com.microsoft.edgemac" }
        func fetchLiveTabs(fetchStart: Date, activeTimes: inout [String: Date], currentFlowSourceAppBundleIdentifier: String?) -> [BrowserSearchResult] { [] }
        func pollActiveTabKeys() -> [String] { [] }
        func fetchAllBookmarks() -> [BrowserSearchResult] { [] }
        func fetchRecentHistory(perBrowserLimit: Int) -> [BrowserSearchResult] { [] }
        func searchHistory(query: String, limit: Int) -> [BrowserSearchResult] { [] }
        func fetchFaviconData(pageURL: String) -> Data? { nil }
        func activateTab(_ result: BrowserSearchResult) {}
        func closeTab(_ result: BrowserSearchResult) {}
        func closeTabWithResult(_ result: BrowserSearchResult, allowPositionalFallback: Bool) -> TabCloseResult { .closed }
        func openURL(_ result: BrowserSearchResult) {}
        func deleteBookmark(_ result: BrowserSearchResult) -> Bool { false }
        func deleteHistoryItem(_ result: BrowserSearchResult) {}
    }

    @Test func sortBrowserSearchResultsOrdersUnpinnedTabsByTimestampDescending() {
        let now = Date()
        let oldest = BrowserSearchResult(
            title: "Oldest Tab",
            url: "https://example.com/old",
            browserName: "Microsoft Edge",
            type: .tab,
            timestamp: now.addingTimeInterval(-3600)
        )
        let middle = BrowserSearchResult(
            title: "Middle Tab",
            url: "https://example.com/mid",
            browserName: "Microsoft Edge",
            type: .tab,
            timestamp: now.addingTimeInterval(-600)
        )
        let newest = BrowserSearchResult(
            title: "Newest Tab",
            url: "https://example.com/new",
            browserName: "Microsoft Edge",
            type: .tab,
            timestamp: now
        )

        // Pass tabs in reverse order
        let sorted = sortBrowserSearchResults([oldest, newest, middle])
        #expect(sorted.map(\.url) == [
            "https://example.com/new",
            "https://example.com/mid",
            "https://example.com/old"
        ])
    }

    @Test func equalTimestampsFallBackToTitleSortRatherThanRecency() {
        let now = Date()
        // When tabs have the exact same timestamp (like in applySnapshotUpdate previously),
        // they get sorted alphabetically by title!
        let zebraTab = BrowserSearchResult(
            title: "Zebra Tab (Recently used)",
            url: "https://example.com/zebra",
            browserName: "Microsoft Edge",
            type: .tab,
            timestamp: now
        )
        let appleTab = BrowserSearchResult(
            title: "Apple Tab (Used hours ago)",
            url: "https://example.com/apple",
            browserName: "Microsoft Edge",
            type: .tab,
            timestamp: now
        )

        let sorted = sortBrowserSearchResults([zebraTab, appleTab])
        // Proves that when timestamps are equal, Apple Tab wins over Zebra Tab alphabetically:
        #expect(sorted.first?.url == "https://example.com/apple")
    }

    @Test func distinctTimestampsEnsureRecentlyUsedWinsOverAlphabeticalTitle() {
        let now = Date()
        let zebraTab = BrowserSearchResult(
            title: "Zebra Tab (Recently used)",
            url: "https://example.com/zebra",
            browserName: "Microsoft Edge",
            type: .tab,
            timestamp: now // 0 seconds ago
        )
        let appleTab = BrowserSearchResult(
            title: "Apple Tab (Used hours ago)",
            url: "https://example.com/apple",
            browserName: "Microsoft Edge",
            type: .tab,
            timestamp: now.addingTimeInterval(-3600) // 1 hour ago
        )

        let sorted = sortBrowserSearchResults([appleTab, zebraTab])
        // Zebra Tab must win because it was used more recently, even though "Apple" < "Zebra"
        #expect(sorted.first?.url == "https://example.com/zebra")
    }
}
