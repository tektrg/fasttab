import Foundation
import Testing
@testable import FastTab

@Test func historyExpansionWindowsStartRecentThenWidenOlder() async throws {
    let now = Date(timeIntervalSince1970: 2_000_000)

    let windows = HistorySearchExpansion.windows(now: now, since: nil, before: nil)

    #expect(windows == [
        HistorySearchWindow(since: now.addingTimeInterval(-7 * 86_400), before: nil),
        HistorySearchWindow(since: now.addingTimeInterval(-30 * 86_400), before: now.addingTimeInterval(-7 * 86_400)),
        HistorySearchWindow(since: now.addingTimeInterval(-90 * 86_400), before: now.addingTimeInterval(-30 * 86_400)),
        HistorySearchWindow(since: now.addingTimeInterval(-365 * 86_400), before: now.addingTimeInterval(-90 * 86_400)),
        HistorySearchWindow(since: nil, before: now.addingTimeInterval(-365 * 86_400))
    ])
}

@Test func historyExpansionWindowsStayInsideExplicitScope() async throws {
    let now = Date(timeIntervalSince1970: 2_000_000)
    let scopeSince = now.addingTimeInterval(-20 * 86_400)
    let scopeBefore = now.addingTimeInterval(-3 * 86_400)

    let windows = HistorySearchExpansion.windows(now: now, since: scopeSince, before: scopeBefore)

    #expect(windows == [
        HistorySearchWindow(since: now.addingTimeInterval(-7 * 86_400), before: scopeBefore),
        HistorySearchWindow(since: scopeSince, before: now.addingTimeInterval(-7 * 86_400))
    ])
}

@Test func finderBoundedHistoryFiltersBeforeApplyingLimit() async throws {
    let store = FinderHistoryStore()
    let backend = FinderBackend(historyStore: store)
    let testID = UUID().uuidString
    let now = Date(timeIntervalSince1970: 2_000_000)
    let olderInScope = now.addingTimeInterval(-10 * 86_400)
    let prefix = "/tmp/fasttab-history-\(testID)"
    let olderPath = "\(prefix)-target"

    defer {
        store.remove(path: olderPath)
        for index in 0..<5 {
            store.remove(path: "\(prefix)-newer-\(index)")
        }
    }

    for index in 0..<5 {
        store.record(path: "\(prefix)-newer-\(index)", at: now.addingTimeInterval(TimeInterval(index)))
    }
    store.record(path: olderPath, at: olderInScope)

    let matches = backend.searchHistory(
        query: "fasttab-history-\(testID)",
        limit: 3,
        since: olderInScope.addingTimeInterval(-60),
        before: olderInScope.addingTimeInterval(60)
    )

    #expect(matches.map(\.url) == [olderPath])
}

@Test func historyExpansionStopsWhenEmptyResultsExhaustBudget() async throws {
    let backend = SlowEmptyHistoryBackend(delaySeconds: 0.03)

    _ = await HistorySearchExpansion.search(
        query: "no-match",
        backends: [backend],
        perBackendLimit: 10,
        since: nil,
        before: nil,
        minimumResults: 5,
        budgetSeconds: 0.01
    )

    #expect(backend.callCount == 1)
}

private final class SlowEmptyHistoryBackend: BrowserBackend, @unchecked Sendable {
    let appName = "Slow Test"
    let bundleIdentifier = "com.example.slow-test"

    private let delaySeconds: TimeInterval
    private let lock = NSLock()
    private var calls = 0

    init(delaySeconds: TimeInterval) {
        self.delaySeconds = delaySeconds
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func fetchLiveTabs(
        fetchStart: Date,
        activeTimes: inout [String: Date],
        currentFlowSourceAppBundleIdentifier: String?
    ) -> [BrowserSearchResult] {
        []
    }

    func pollActiveTabKeys() -> [String] { [] }
    func fetchAllBookmarks() -> [BrowserSearchResult] { [] }
    func fetchRecentHistory(perBrowserLimit: Int) -> [BrowserSearchResult] { [] }
    func searchHistory(query: String, limit: Int) -> [BrowserSearchResult] { [] }
    func searchHistory(query: String, limit: Int, since: Date?, before: Date?) -> [BrowserSearchResult] { [] }

    func searchHistory(
        query: String,
        limit: Int,
        since: Date?,
        before: Date?,
        timeoutSeconds: TimeInterval
    ) -> [BrowserSearchResult] {
        lock.lock()
        calls += 1
        lock.unlock()
        Thread.sleep(forTimeInterval: delaySeconds)
        return []
    }

    func fetchFaviconData(pageURL: String) -> Data? { nil }
    func activateTab(_ result: BrowserSearchResult) {}
    func closeTab(_ result: BrowserSearchResult) {}
    func openURL(_ result: BrowserSearchResult) {}
    func deleteBookmark(_ result: BrowserSearchResult) {}
    func deleteHistoryItem(_ result: BrowserSearchResult) {}
}
