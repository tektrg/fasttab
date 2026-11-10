import Combine
import FastTabSync
import XCTest
@testable import FastTabMobile

/// Regression guards for the "typing lags in the comment sheet / phone warms up while reading"
/// fix: unchanged data must not re-publish (every publish re-renders the screens observing it),
/// the idle poll backs off, and scrolling persists progress at a bounded rate.
@MainActor
final class PerformancePublishTests: XCTestCase {
    private var bag = Set<AnyCancellable>()

    override func tearDown() async throws {
        bag.removeAll()
    }

    private func countPublishes<P: ObservableObject>(of object: P) -> () -> Int {
        var count = 0
        object.objectWillChange.sink { _ in count += 1 }.store(in: &bag)
        return { count }
    }

    // MARK: - LocalCache

    func testLocalCacheReDeliveredIdenticalTabDoesNotPublish() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("perf-cache-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let cache = LocalCache(customFileURL: file)
        let tab = SyncedTab(id: "t1", deviceID: "mac", browserName: "Safari", title: "A", url: "https://example.com/a")
        cache.updateTab(tab)
        let publishes = countPublishes(of: cache)

        cache.updateTab(tab)
        XCTAssertEqual(publishes(), 0, "an unchanged tab from a poll must not re-render the app")

        cache.updateTab(SyncedTab(id: "t1", deviceID: "mac", browserName: "Safari", title: "B", url: "https://example.com/a"))
        XCTAssertGreaterThan(publishes(), 0)
        XCTAssertEqual(cache.state.tabs.first?.title, "B")
    }

    // MARK: - SyncConsumer (pure decisions; the class needs CloudKit)

    func testPollBacksOffAfterEmptyPollsAndCaps() {
        let intervals = (0...8).map { SyncConsumer.pollInterval(afterEmptyPolls: $0) }
        XCTAssertEqual(intervals, [6, 6, 6, 12, 24, 30, 30, 30, 30])
    }

    func testSuccessStampMovesAtMostEvery30Seconds() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(SyncConsumer.shouldRefreshSuccessStamp(previous: nil, now: t0))
        XCTAssertFalse(SyncConsumer.shouldRefreshSuccessStamp(previous: t0, now: t0.addingTimeInterval(6)))
        XCTAssertTrue(SyncConsumer.shouldRefreshSuccessStamp(previous: t0, now: t0.addingTimeInterval(30)))
        XCTAssertTrue(SyncConsumer.shouldRefreshSuccessStamp(previous: t0, now: t0.addingTimeInterval(-1)),
                      "a clock moved backwards must not freeze the stamp")
    }

    // MARK: - Comment threads

    func testReloadingUnchangedCommentThreadsDoesNotPublish() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("perf-comments-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let threads = ReaderCommentThreads(directory: directory, linkThread: { _, _ in true })
        let h = ReaderHighlight(id: UUID().uuidString, urlKey: "https://example.com/a", selectedText: "beta gamma",
                                color: .yellow, serializedRange: #"{"text":"beta gamma","start":6,"len":10}"#)
        try await threads.post("first", on: h)
        await threads.load([h]).value
        let publishes = countPublishes(of: threads)

        await threads.load([h]).value
        XCTAssertEqual(publishes(), 0, "a sync-tick reload with nothing new must not re-render the reader")
        XCTAssertEqual(threads.thread(for: h)?.messages.map(\.text), ["first"])
    }

    // MARK: - Reading progress

    func testScrollingPersistsProgressAtABoundedRateAndFlushesTheLatest() async throws {
        let url = URL(string: "https://example.com/perf-throttle-\(UUID().uuidString)")!
        let vm = ReaderViewModel(url: url, title: "Throttle", statsRecorder: .isolatedForTests())
        vm.progressPersistInterval = .milliseconds(200)

        vm.updateScrollProgress(0.2)
        vm.updateScrollProgress(0.3, immediate: true)
        XCTAssertEqual(ReaderReadingProgress.shared.progress(for: url), 0, "nothing written mid-scroll")

        try await Task.sleep(for: .milliseconds(150))
        vm.updateScrollProgress(0.4)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(ReaderReadingProgress.shared.progress(for: url), 0.4, accuracy: 0.001,
                       "continuous scrolling still saves the newest value once per interval")

        vm.updateScrollProgress(0.5)
        vm.flushPendingProgress()
        XCTAssertEqual(ReaderReadingProgress.shared.progress(for: url), 0.5, accuracy: 0.001)
    }

    func testReachingTheEndPersistsImmediately() {
        let url = URL(string: "https://example.com/perf-end-\(UUID().uuidString)")!
        let vm = ReaderViewModel(url: url, title: "End", statsRecorder: .isolatedForTests())
        vm.updateScrollProgress(1, immediate: true)
        XCTAssertEqual(ReaderReadingProgress.shared.progress(for: url), 1, accuracy: 0.001)
    }
}
