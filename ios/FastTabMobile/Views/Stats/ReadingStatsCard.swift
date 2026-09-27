import SwiftUI
import Charts

/// More tab: what you read in Reader over the last weeks, split by topic.
struct ReadingStatsCard: View {
    let summary: ReadingStatsSummary
    /// Before the log is read, the empty message shows as a placeholder shape.
    var isLoaded = true

    var body: some View {
        StatsCard(
            title: "Reading",
            systemImage: "book.pages",
            tint: DS.Tint.recent,
            context: "Last \(ReadingStatsSummary.chartedWeekCount) weeks"
        ) {
            if summary.isEmpty {
                StatsEmptyMessage(
                    systemImage: "text.book.closed",
                    message: "Open an article in Reader. Words you read, articles you finish and highlights show up here."
                )
                .redacted(reason: isLoaded ? [] : .placeholder)
            } else {
                HStack(spacing: DS.Space.md) {
                    StatTile(value: StatsStyle.compactNumber(summary.totalWords), caption: "words read")
                    StatTile(value: "\(summary.finishedCount)", caption: "finished")
                    StatTile(value: "\(summary.highlightCount)", caption: "highlights", tint: DS.Tint.warning)
                }
                if summary.totalWords > 0 {
                    ChartCaption(text: "Words per week")
                    weeklyWordsChart
                    TopicShareBar(shares: summary.topicShares, colorFor: color(forTopic:))
                }
            }
        }
    }

    private var chartTopics: [String] { summary.topicShares.map(\.topic) }

    private func color(forTopic topic: String) -> Color {
        guard topic != ReadingStatsSummary.otherTopic, let index = chartTopics.firstIndex(of: topic) else {
            return StatsStyle.otherTopicColor
        }
        return StatsStyle.topicColors[index % StatsStyle.topicColors.count]
    }

    private var weekDomain: ClosedRange<Date> {
        let start = summary.windowStart ?? Date()
        let end = Calendar.current.date(byAdding: .weekOfYear, value: ReadingStatsSummary.chartedWeekCount, to: start) ?? Date()
        return start...end
    }

    private var weeklyWordsChart: some View {
        Chart(summary.wordsByWeekAndTopic) { point in
            BarMark(
                x: .value("Week", point.weekStart, unit: .weekOfYear),
                y: .value("Words", point.words),
                width: .ratio(0.62)
            )
            .foregroundStyle(by: .value("Topic", point.topic))
        }
        .chartForegroundStyleScale(domain: chartTopics, range: chartTopics.map(color(forTopic:)))
        .chartLegend(.hidden)
        .chartXScale(domain: weekDomain)
        .chartXAxis {
            AxisMarks(values: .stride(by: .weekOfYear, count: 2)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated).day(), centered: false)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(DS.Palette.hairline)
                AxisValueLabel {
                    if let words = value.as(Double.self) { Text(StatsStyle.compactNumber(words)) }
                }
            }
        }
        .frame(height: StatsStyle.chartHeight)
        .accessibilityLabel("Words read per week, by topic")
    }
}

/// One capsule split by topic share, with a wrapped legend underneath.
private struct TopicShareBar: View {
    let shares: [ReadingStatsSummary.TopicShare]
    let colorFor: (String) -> Color

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    ForEach(shares) { share in
                        colorFor(share.topic)
                            .frame(width: max(3, (proxy.size.width - CGFloat(shares.count - 1) * 2) * share.share))
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 8)

            FlowingLegend(shares: shares, colorFor: colorFor)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct FlowingLegend: View {
    let shares: [ReadingStatsSummary.TopicShare]
    let colorFor: (String) -> Color

    var body: some View {
        WrappingRowsLayout(spacing: DS.Space.md, lineSpacing: DS.Space.xs) { entries }
    }

    private var entries: some View {
        ForEach(shares) { share in
            HStack(spacing: DS.Space.xs) {
                Circle().fill(colorFor(share.topic)).frame(width: 7, height: 7)
                Text(share.topic)
                    .font(DS.Font.meta)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(share.share.formatted(.percent.precision(.fractionLength(0))))
                    .font(DS.Font.meta.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}
