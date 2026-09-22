import Foundation
import Testing
@testable import FastTab

@Suite("Recent Sort Repro Tests", .serialized)
struct RecentSortReproTests {

    private final class MockBridge: ExtensionBridgeServing, @unchecked Sendable {
        var view: ExtensionSnapshotView?
        func snapshotView(for appName: String, profileCount: Int) -> ExtensionSnapshotView? { view }
        func isConnected(appName: String) -> Bool { view != nil }
        func sendCommand(appName: String, type: String, tabID: Int, extraPayload: [String: Any], timeout: TimeInterval) -> Bool { false }
    }

    private final class DummyBackend: BrowserBackend, ChromiumProfileAccess, @unchecked Sendable {
        var appName: String { "Microsoft Edge" }
        var bundleIdentifier: String { "com.microsoft.edgemac" }
        func profileCount() -> Int { 1 }
        func chromiumProfiles() -> [ChromiumProfile] { [] }
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

    @Test func decodeTabExtractsLastAccessedTimestamp() {
        let epochMS: Double = 1716123456789
        let dict: [String: Any] = [
            "id": 101,
            "windowIndex": 1,
            "tabIndex": 1,
            "title": "Decoded Tab",
            "url": "https://example.com/decoded",
            "lastAccessed": epochMS
        ]
        let record = ExtensionBridge.decodeTab(dict)
        #expect(record != nil)
        #expect(record?.lastAccessed == Date(timeIntervalSince1970: 1716123456.789))
    }

    @Test func applySnapshotPopulatesActivationTimesFromLastAccessed() {
        var connection = ConnectionState()
        let accessedTime = Date(timeIntervalSince1970: 1716123456.789)
        let tab = ExtensionTabRecord(
            tabID: 42,
            windowIndex: 1,
            tabIndex: 1,
            title: "Test Tab",
            url: "https://example.com/tab",
            windowName: "Win 1",
            isActive: false,
            isAudible: false,
            isMuted: false,
            isPinned: false,
            isDiscarded: false,
            groupTitle: nil,
            lastAccessed: accessedTime
        )
        ExtensionBridge.applySnapshot(&connection, tabs: [tab])
        #expect(connection.activationTimes[42] == accessedTime)
    }

    @Test func extensionBackedBackendOrdersTabsByLastAccessed() {
        ExtensionBetaPreference.setEnabled(true)
        defer { ExtensionBetaPreference.setEnabled(false) }

        let now = Date()
        let zebraTime = now.addingTimeInterval(-10)   // 10s ago (recently used)
        let appleTime = now.addingTimeInterval(-3600) // 1h ago

        let zebraRecord = ExtensionTabRecord(
            tabID: 1,
            windowIndex: 1,
            tabIndex: 1,
            title: "Zebra Tab (Recently used)",
            url: "https://example.com/zebra",
            windowName: "Win 1",
            isActive: false,
            isAudible: false,
            isMuted: false,
            isPinned: false,
            isDiscarded: false,
            groupTitle: nil,
            lastAccessed: zebraTime
        )
        let appleRecord = ExtensionTabRecord(
            tabID: 2,
            windowIndex: 1,
            tabIndex: 2,
            title: "Apple Tab (Used 1 hour ago)",
            url: "https://example.com/apple",
            windowName: "Win 1",
            isActive: false,
            isAudible: false,
            isMuted: false,
            isPinned: false,
            isDiscarded: false,
            groupTitle: nil,
            lastAccessed: appleTime
        )

        let mockBridge = MockBridge()
        mockBridge.view = ExtensionSnapshotView(
            tabs: [appleRecord, zebraRecord],
            activationTimes: [1: zebraTime, 2: appleTime]
        )

        let backend = ExtensionBackedBackend(inner: DummyBackend(), bridge: mockBridge)
        var activeTimes: [String: Date] = [:]
        let results = backend.fetchLiveTabs(fetchStart: now, activeTimes: &activeTimes, currentFlowSourceAppBundleIdentifier: nil)

        // Zebra was accessed 10s ago, Apple 3600s ago
        let sorted = sortBrowserSearchResults(results)
        #expect(sorted.count == 2)
        #expect(sorted.first?.title == "Zebra Tab (Recently used)")
        #expect(sorted.last?.title == "Apple Tab (Used 1 hour ago)")
    }

    @Test func extensionBackedBackendDoesNotPolluteActiveTimesWithEpochZero() {
        ExtensionBetaPreference.setEnabled(true)
        defer { ExtensionBetaPreference.setEnabled(false) }

        let tabWithoutAccess = ExtensionTabRecord(
            tabID: 99,
            windowIndex: 1,
            tabIndex: 1,
            title: "No Access Tab",
            url: "https://example.com/no-access",
            windowName: "Win 1",
            isActive: false,
            isAudible: false,
            isMuted: false,
            isPinned: false,
            isDiscarded: false,
            groupTitle: nil,
            lastAccessed: nil
        )

        let mockBridge = MockBridge()
        mockBridge.view = ExtensionSnapshotView(
            tabs: [tabWithoutAccess],
            activationTimes: [:]
        )

        let backend = ExtensionBackedBackend(inner: DummyBackend(), bridge: mockBridge)
        var activeTimes: [String: Date] = [:]
        _ = backend.fetchLiveTabs(fetchStart: Date(), activeTimes: &activeTimes, currentFlowSourceAppBundleIdentifier: nil)

        #expect(activeTimes.isEmpty)
    }

    @Test func quickOpenRanksRecentlyUsedUnpinnedTabAboveOlderPinnedTab() {
        let now = Date()
        let pinnedOldTab = BrowserSearchResult(
            title: "Pinned Tab (Used 2 hours ago)",
            url: "https://example.com/pinned",
            browserName: "Google Chrome",
            type: .tab,
            timestamp: now.addingTimeInterval(-7200),
            isPinned: true
        )
        let unpinnedRecentTab = BrowserSearchResult(
            title: "Unpinned Tab (Used 5 seconds ago)",
            url: "https://example.com/unpinned",
            browserName: "Google Chrome",
            type: .tab,
            timestamp: now.addingTimeInterval(-5),
            isPinned: false
        )

        let results = allQuickOpenTabs(from: [pinnedOldTab, unpinnedRecentTab])
        #expect(results.first?.url == "https://example.com/unpinned")
    }

    @Test func sortQuickOpenResultsOmitsSentLinksAndRanksTabsByRecencyWithoutPinnedBias() {
        let now = Date()
        let sentLink = BrowserSearchResult(
            title: "Sent Link from Mobile",
            url: "https://example.com/sent",
            browserName: "FastTab",
            type: .sent,
            timestamp: now.addingTimeInterval(-100)
        )
        let pinnedOldTab = BrowserSearchResult(
            title: "Pinned Old Tab",
            url: "https://example.com/pinned-old",
            browserName: "Google Chrome",
            type: .tab,
            timestamp: now.addingTimeInterval(-3600),
            isPinned: true
        )
        let unpinnedRecentTab = BrowserSearchResult(
            title: "Unpinned Recent Tab",
            url: "https://example.com/recent",
            browserName: "Google Chrome",
            type: .tab,
            timestamp: now.addingTimeInterval(-10),
            isPinned: false
        )

        // In quick open results:
        // 1. Sent link is omitted (it lives in My Order)
        // 2. Unpinned recent tab first (timestamp: -10s)
        // 3. Pinned old tab second (timestamp: -3600s)
        let quickOpenResults = sortQuickOpenResults([pinnedOldTab, sentLink, unpinnedRecentTab])
        #expect(quickOpenResults.map(\.url) == [
            "https://example.com/recent",
            "https://example.com/pinned-old"
        ])

        // In contrast, sortBrowserSearchResults promotes pinned tabs to the top tier ahead of unpinned:
        let searchResults = sortBrowserSearchResults([pinnedOldTab, unpinnedRecentTab])
        #expect(searchResults.first?.url == "https://example.com/pinned-old")
    }

    @Test func sortQuickOpenResultsNeverLetsSentLinkBacklogHideRecentTab() {
        let now = Date()
        let sentLinks = (1...6).map { n in
            BrowserSearchResult(
                title: "Sent \(n)",
                url: "https://example.com/sent\(n)",
                browserName: "iPhone",
                type: .sent,
                timestamp: now.addingTimeInterval(-Double(n))
            )
        }
        let activeTab = BrowserSearchResult(
            title: "Active Tab",
            url: "https://example.com/active",
            browserName: "Google Chrome",
            type: .tab,
            timestamp: now.addingTimeInterval(-5000)
        )

        #expect(sortQuickOpenResults(sentLinks + [activeTab]).map(\.url) == ["https://example.com/active"])
        #expect(sortQuickOpenResults(sentLinks).isEmpty)
    }
}
