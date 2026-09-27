import XCTest
import IndieMetrics
import FastTabSync
@testable import FastTabMobile

/// In-memory log, so tests never touch the app's real reading log.
actor InMemoryMetricEventLog: MetricEventStoring {
    private(set) var events: [MetricEvent] = []

    init(events: [MetricEvent] = []) { self.events = events }

    func append(_ newEvents: [MetricEvent]) { events += newEvents }
    func loadEvents() -> [MetricEvent] { events }
    func prune(olderThan cutoff: Date?, maxEvents: Int?) -> Int {
        let before = events.count
        if let cutoff { events.removeAll { $0.timestamp < cutoff } }
        return before - events.count
    }
}

final class ReadingProgressLedgerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testOnlyNewGroundCountsAndScrollingBackNeverSubtracts() {
        var ledger = ReadingProgressLedger()
        XCTAssertEqual(ledger.advance(articleKey: "a", to: 0.3, isFlush: false, now: now).newlyReadFraction, 0.3, accuracy: 1e-9)
        XCTAssertEqual(ledger.advance(articleKey: "a", to: 0.1, isFlush: true, now: now), .nothing)
        XCTAssertEqual(ledger.advance(articleKey: "a", to: 0.5, isFlush: false, now: now).newlyReadFraction, 0.2, accuracy: 1e-9)
    }

    func testSmallGainsWaitForAFlush() {
        var ledger = ReadingProgressLedger()
        _ = ledger.advance(articleKey: "a", to: 0.2, isFlush: false, now: now)
        XCTAssertEqual(ledger.advance(articleKey: "a", to: 0.22, isFlush: false, now: now), .nothing)
        XCTAssertEqual(ledger.advance(articleKey: "a", to: 0.23, isFlush: true, now: now).newlyReadFraction, 0.03, accuracy: 1e-9)
    }

    func testFinishedIsReportedOnce() {
        var ledger = ReadingProgressLedger()
        XCTAssertTrue(ledger.advance(articleKey: "a", to: 0.92, isFlush: false, now: now).didFinish)
        XCTAssertFalse(ledger.advance(articleKey: "a", to: 1.0, isFlush: true, now: now).didFinish)
        _ = ledger.advance(articleKey: "a", to: 0.1, isFlush: true, now: now)
        XCTAssertFalse(ledger.advance(articleKey: "a", to: 0.95, isFlush: true, now: now).didFinish)
    }

    func testSeedKeepsProgressFromBeforeStatsOutOfTheCount() {
        var ledger = ReadingProgressLedger()
        ledger.seedIfUnknown(articleKey: "a", progress: 0.6, now: now)
        ledger.seedIfUnknown(articleKey: "a", progress: 0.0, now: now)
        XCTAssertEqual(ledger.advance(articleKey: "a", to: 0.7, isFlush: true, now: now).newlyReadFraction, 0.1, accuracy: 1e-9)
    }
}

@MainActor
final class ReadingStatsRecorderTests: XCTestCase {
    private var defaults: UserDefaults!
    private let articleURL = URL(string: "https://www.example.com/posts/swift?utm_source=x")!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "ReadingStatsRecorderTests")
        defaults.removePersistentDomain(forName: "ReadingStatsRecorderTests")
    }

    private func makeRecorder(log: InMemoryMetricEventLog, isTrackable: @escaping (URL) -> Bool = { _ in true }) -> ReadingStatsRecorder {
        ReadingStatsRecorder(log: log, defaults: defaults, isTrackable: isTrackable)
    }

    func testWordsAreWordCountTimesNewGroundAndFinishedLandsOnce() async {
        let log = InMemoryMetricEventLog()
        let recorder = makeRecorder(log: log)
        recorder.beginReading(url: articleURL, savedProgress: 0)
        recorder.recordProgress(url: articleURL, title: "Swift", progress: 0.5, wordCount: 1_000, isFlush: false)
        recorder.recordProgress(url: articleURL, title: "Swift", progress: 0.2, wordCount: 1_000, isFlush: true)
        recorder.recordProgress(url: articleURL, title: "Swift", progress: 1.0, wordCount: 1_000, isFlush: true)
        recorder.recordProgress(url: articleURL, title: "Swift", progress: 1.0, wordCount: 1_000, isFlush: true)
        await recorder.waitForPendingWrites()

        let events = await log.events
        XCTAssertEqual(events.filter { $0.metric == ReadingMetric.words }.map(\.value), [500, 500])
        XCTAssertEqual(events.filter { $0.metric == ReadingMetric.finished }.count, 1)
        XCTAssertEqual(Set(events.map(\.subject)), [articleURL.readerCanonicalKey])
        XCTAssertEqual(events.first?.labels[ReadingMetric.hostLabel], "example.com")
        XCTAssertEqual(events.first?.labels[ReadingMetric.titleLabel], "Swift")
    }

    func testHighWaterSurvivesARelaunch() async {
        let log = InMemoryMetricEventLog()
        let firstLaunch = makeRecorder(log: log)
        firstLaunch.recordProgress(url: articleURL, title: "", progress: 0.4, wordCount: 100, isFlush: true)
        await firstLaunch.waitForPendingWrites()
        let relaunched = makeRecorder(log: log)
        relaunched.recordProgress(url: articleURL, title: "", progress: 0.4, wordCount: 100, isFlush: true)
        await relaunched.waitForPendingWrites()
        let wordEvents = await log.events.filter { $0.metric == ReadingMetric.words }
        XCTAssertEqual(wordEvents.map(\.value), [40])
    }

    func testEachNewHighlightCounts() async {
        let log = InMemoryMetricEventLog()
        let recorder = makeRecorder(log: log)
        recorder.recordHighlight(url: articleURL, title: "Swift")
        recorder.recordHighlight(url: articleURL, title: "Swift")
        await recorder.waitForPendingWrites()
        let highlightCount = await log.events.filter { $0.metric == ReadingMetric.highlight }.count
        XCTAssertEqual(highlightCount, 2)
    }

    func testUntrackablePagesRecordNothing() async {
        let log = InMemoryMetricEventLog()
        let recorder = makeRecorder(log: log, isTrackable: { _ in false })
        recorder.recordProgress(url: articleURL, title: "", progress: 1, wordCount: 100, isFlush: true)
        recorder.recordHighlight(url: articleURL, title: "")
        await recorder.waitForPendingWrites()
        let eventCount = await log.events.count
        XCTAssertEqual(eventCount, 0)
    }

    func testGateSkipsToolsAndCountsUnclassifiedReads() {
        XCTAssertFalse(ReadingStatsRecorder.isTrackableRead(URL(string: "https://mail.google.com/mail/u/0/")!))
        XCTAssertFalse(ReadingStatsRecorder.isTrackableRead(URL(string: "https://example.com/")!))
        // Never classified by the on-device model (nil) still counts as a read.
        XCTAssertTrue(ReadingStatsRecorder.isTrackableRead(URL(string: "https://unclassified-\(UUID().uuidString).com/essay")!))
    }

    func testWordCountStripsMarkup() {
        let article = ReaderArticle(
            title: "T",
            content: "<p>One two&nbsp;<b>three</b></p><script>var ignored = 1;</script><p>four</p>",
            url: articleURL
        )
        XCTAssertEqual(article.readingWordCount, 4)
    }
}

@MainActor
final class ReadingTopicResolverTests: XCTestCase {
    func testFallbackOrderIsBookmarkThenInferredThenHostThenUncategorized() {
        XCTAssertEqual(ReadingTopicResolver.topic(bookmarkFolder: "Swift", inferredFolder: "AI", host: "a.com"), "Swift")
        XCTAssertEqual(ReadingTopicResolver.topic(bookmarkFolder: nil, inferredFolder: "AI", host: "a.com"), "AI")
        XCTAssertEqual(ReadingTopicResolver.topic(bookmarkFolder: " ", inferredFolder: "", host: "a.com"), "a.com")
        XCTAssertEqual(ReadingTopicResolver.topic(bookmarkFolder: nil, inferredFolder: nil, host: nil), ReadingTopicResolver.uncategorized)
    }

    func testBookmarkFolderMatchesByCanonicalKey() {
        let blob = SyncedBookmarkBlob(
            deviceID: "mac",
            browserName: "Chrome",
            profileName: "Default",
            bookmarks: [
                SyncedBookmarkItem(id: "1", title: "Post", url: "https://Example.com/post#top", folderPath: "Bookmarks Bar / Swift", dateAdded: nil),
                SyncedBookmarkItem(id: "2", title: "Loose", url: "https://example.com/loose", folderPath: nil, dateAdded: nil)
            ]
        )
        let folders = ReadingTopicResolver.bookmarkFolderByArticle(in: [blob])
        XCTAssertEqual(folders[URL(string: "https://example.com/post")!.readerCanonicalKey], "Swift")
        XCTAssertNil(folders[URL(string: "https://example.com/loose")!.readerCanonicalKey])
    }

    func testEventsWithoutBookmarkOrInferenceFallBackToHost() {
        let suite = "ReadingTopicResolverTests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let resolver = ReadingTopicResolver(defaults: defaults)
        let event = MetricEvent(timestamp: Date(), subject: "https://a.com/x", metric: ReadingMetric.words, labels: [ReadingMetric.hostLabel: "a.com"])
        XCTAssertEqual(resolver.topicsByArticle(for: [event], bookmarkBlobs: []), ["https://a.com/x": "a.com"])
    }
}
