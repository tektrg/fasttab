import Foundation
import IndieMetrics

/// Chart-ready reading stats over the last `chartedWeekCount` weeks, from the reading log.
struct ReadingStatsSummary: Equatable {
    struct TopicWeekWords: Equatable, Identifiable {
        let weekStart: Date
        let topic: String
        let words: Double
        var id: String { "\(weekStart.timeIntervalSince1970)|\(topic)" }
    }

    struct TopicShare: Equatable, Identifiable {
        let topic: String
        let words: Double
        /// 0...1 of all words in the window.
        let share: Double
        var id: String { topic }
    }

    static let chartedWeekCount = 8
    /// Topics charted by name; the rest are summed into `otherTopic`.
    static let namedTopicLimit = 4
    static let otherTopic = "Other"

    var wordsByWeekAndTopic: [TopicWeekWords] = []
    /// Largest topics first, `otherTopic` last. Also the chart's color order.
    var topicShares: [TopicShare] = []
    var totalWords: Double = 0
    var finishedCount: Int = 0
    var highlightCount: Int = 0
    /// First day of the charted window, for the axis domain.
    var windowStart: Date?

    static let empty = ReadingStatsSummary()
    var isEmpty: Bool { totalWords == 0 && finishedCount == 0 && highlightCount == 0 }

    /// `topicsByArticle`: article subject -> topic (from `ReadingTopicResolver`); missing ones
    /// fall under `ReadingTopicResolver.uncategorized`.
    static func make(
        from events: [MetricEvent],
        topicsByArticle: [String: String],
        now: Date,
        calendar: Calendar
    ) -> ReadingStatsSummary {
        let thisWeek = bucketStart(now, period: .week, calendar: calendar).startDate ?? now
        let windowStart = calendar.date(byAdding: .weekOfYear, value: -(chartedWeekCount - 1), to: thisWeek) ?? thisWeek
        let window = DateInterval(start: windowStart, end: max(now, windowStart).addingTimeInterval(1))

        let byTopic = MetricGrouping.key { topicsByArticle[$0.subject] ?? ReadingTopicResolver.uncategorized }
        let wordsPerTopic = MetricQuery(metric: ReadingMetric.words, interval: window, period: .month, grouping: byTopic, reducer: .sum)
        let totalsByTopic = Dictionary(
            wordsPerTopic.points(from: events, calendar: calendar).map { ($0.group ?? "", $0.value) },
            uniquingKeysWith: +
        )
        let namedTopics = Set(totalsByTopic.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .prefix(namedTopicLimit).map(\.key))
        let chartTopic: @Sendable (String) -> String = { namedTopics.contains($0) ? $0 : otherTopic }

        let weeklyWords = MetricQuery(
            metric: ReadingMetric.words,
            interval: window,
            period: .week,
            grouping: .key { chartTopic(topicsByArticle[$0.subject] ?? ReadingTopicResolver.uncategorized) },
            reducer: .sum
        ).points(from: events, calendar: calendar)

        let totalWords = totalsByTopic.values.reduce(0, +)
        var wordsByChartTopic: [String: Double] = [:]
        for (topic, words) in totalsByTopic { wordsByChartTopic[chartTopic(topic), default: 0] += words }
        let shares = wordsByChartTopic
            .map { TopicShare(topic: $0.key, words: $0.value, share: totalWords > 0 ? $0.value / totalWords : 0) }
            .sorted { lhs, rhs in
                if (lhs.topic == otherTopic) != (rhs.topic == otherTopic) { return rhs.topic == otherTopic }
                return (lhs.words, rhs.topic) > (rhs.words, lhs.topic)
            }

        func count(_ metric: String) -> Int {
            Int(MetricQuery(metric: metric, interval: window, period: .month, reducer: .count)
                .points(from: events, calendar: calendar).map(\.value).reduce(0, +))
        }

        return ReadingStatsSummary(
            wordsByWeekAndTopic: weeklyWords.compactMap { point in
                point.bucket.startDate.map { TopicWeekWords(weekStart: $0, topic: point.group ?? otherTopic, words: point.value) }
            },
            topicShares: shares,
            totalWords: totalWords,
            finishedCount: count(ReadingMetric.finished),
            highlightCount: count(ReadingMetric.highlight),
            windowStart: windowStart
        )
    }
}
