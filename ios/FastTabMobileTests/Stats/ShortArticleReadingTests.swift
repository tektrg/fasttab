import XCTest
import IndieMetrics
@testable import FastTabMobile

/// Articles that fit on one screen never scroll, so the reader page reports "fits the viewport"
/// instead, and staying on it for the dwell counts as reading it to the end.
@MainActor
final class ShortArticleReadingTests: XCTestCase {
    private let articleURL = URL(string: "https://example.com/posts/short-article-stats-test")!
    private let shortDwell: Duration = .milliseconds(50)

    override func tearDown() {
        ReaderReadingProgress.shared.set(progress: 0, for: articleURL)
        super.tearDown()
    }

    private func makeLoadedViewModel(log: InMemoryMetricEventLog) -> ReaderViewModel {
        let recorder = ReadingStatsRecorder.isolatedForTests(log: log, isTrackable: { _ in true })
        let viewModel = ReaderViewModel(url: articleURL, title: "Short", statsRecorder: recorder,
                                        fitsOnScreenDwell: shortDwell)
        viewModel.loadState = .loaded(ReaderArticle(title: "Short", content: "<p>one two three four</p>", url: articleURL))
        return viewModel
    }

    /// Waits well past the dwell and the off-main word count, then returns what was logged.
    private func eventsAfterSettling(_ log: InMemoryMetricEventLog) async throws -> [MetricEvent] {
        try await Task.sleep(for: .milliseconds(500))
        return await log.events
    }

    func testFittingArticleCountsAsFinishedAfterTheDwell() async throws {
        let log = InMemoryMetricEventLog()
        let viewModel = makeLoadedViewModel(log: log)

        viewModel.contentFitsViewportChanged(true)
        let events = try await eventsAfterSettling(log)

        XCTAssertEqual(viewModel.scrollProgress, 1, accuracy: 0.001)
        XCTAssertEqual(events.filter { $0.metric == ReadingMetric.words }.map(\.value), [4])
        XCTAssertEqual(events.filter { $0.metric == ReadingMetric.finished }.count, 1)
    }

    func testClosingBeforeTheDwellCountsNothing() async throws {
        let log = InMemoryMetricEventLog()
        let viewModel = makeLoadedViewModel(log: log)

        viewModel.contentFitsViewportChanged(true)
        viewModel.flushPendingProgress()
        let events = try await eventsAfterSettling(log)

        XCTAssertEqual(viewModel.scrollProgress, 0, accuracy: 0.001)
        XCTAssertTrue(events.isEmpty)
    }

    func testContentGrowingPastTheScreenCancelsTheDwell() async throws {
        let log = InMemoryMetricEventLog()
        let viewModel = makeLoadedViewModel(log: log)

        viewModel.contentFitsViewportChanged(true)
        viewModel.contentFitsViewportChanged(false)
        let events = try await eventsAfterSettling(log)

        XCTAssertEqual(viewModel.scrollProgress, 0, accuracy: 0.001)
        XCTAssertTrue(events.isEmpty)
    }
}
