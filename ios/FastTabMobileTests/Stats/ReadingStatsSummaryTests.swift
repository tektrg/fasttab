import XCTest
import IndieMetrics
@testable import FastTabMobile

final class ReadingStatsSummaryTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }()
    private let now = Date(timeIntervalSince1970: 1_790_000_000) // a Wednesday

    private func words(_ subject: String, _ value: Double, daysAgo: Double = 0) -> MetricEvent {
        MetricEvent(timestamp: now.addingTimeInterval(-daysAgo * 86_400), subject: subject, metric: ReadingMetric.words, value: value)
    }

    func testTopTopicsAreNamedAndTheRestFoldIntoOther() {
        let subjects = ["a", "b", "c", "d", "e", "f"]
        let events = subjects.enumerated().map { words($0.element, Double(100 * ($0.offset + 1))) }
        let topics = Dictionary(uniqueKeysWithValues: subjects.map { ($0, "topic-\($0)") })
        let summary = ReadingStatsSummary.make(from: events, topicsByArticle: topics, now: now, calendar: calendar)

        XCTAssertEqual(summary.topicShares.map(\.topic), ["topic-f", "topic-e", "topic-d", "topic-c", ReadingStatsSummary.otherTopic])
        XCTAssertEqual(summary.topicShares.last?.words, 300)
        XCTAssertEqual(summary.totalWords, 2_100)
        XCTAssertEqual(summary.topicShares.map(\.share).reduce(0, +), 1, accuracy: 1e-9)
    }

    func testOldEventsFallOutsideTheWindowAndCountsAreTallied() {
        let events = [
            words("a", 500, daysAgo: 2),
            words("a", 900, daysAgo: 70),
            MetricEvent(timestamp: now, subject: "a", metric: ReadingMetric.finished),
            MetricEvent(timestamp: now, subject: "a", metric: ReadingMetric.highlight),
            MetricEvent(timestamp: now, subject: "b", metric: ReadingMetric.highlight)
        ]
        let summary = ReadingStatsSummary.make(from: events, topicsByArticle: [:], now: now, calendar: calendar)
        XCTAssertEqual(summary.totalWords, 500)
        XCTAssertEqual(summary.finishedCount, 1)
        XCTAssertEqual(summary.highlightCount, 2)
        XCTAssertEqual(summary.wordsByWeekAndTopic.map(\.topic), [ReadingTopicResolver.uncategorized])
    }
}
