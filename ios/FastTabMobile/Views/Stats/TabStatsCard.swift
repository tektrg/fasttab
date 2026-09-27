import SwiftUI
import Charts

/// More tab: browser-tab habits across every Mac (open tabs over time, tabs opened, busiest times).
struct TabStatsCard: View {
    let summary: TabStatsSummary
    /// Days the headline averages cover.
    private static let headlineDayCount = 7

    var body: some View {
        StatsCard(
            title: "Tabs",
            systemImage: "macwindow.on.rectangle",
            tint: DS.Tint.action,
            context: "All Macs · \(TabStatsSummary.chartedDayCount) days"
        ) {
            if summary.isEmpty {
                StatsEmptyMessage(
                    systemImage: "chart.xyaxis.line",
                    message: "Tab activity appears once a Mac running the latest FastTab syncs its daily summary."
                )
            } else {
                headlineTiles
                if !summary.averageOpenByDay.isEmpty {
                    ChartCaption(text: "Open at once, daily average")
                    averageOpenChart
                }
                if !summary.openedByDay.isEmpty {
                    ChartCaption(text: "Opened per day")
                    openedPerDayChart
                }
                if summary.busiestHour != nil {
                    ChartCaption(text: "When you open tabs")
                    openedByHourChart
                }
            }
        }
    }

    private var headlineTiles: some View {
        HStack(spacing: DS.Space.md) {
            StatTile(
                value: TabStatsSummary.recentMean(summary.averageOpenByDay, days: Self.headlineDayCount, missingDaysAsZero: false, now: Date(), calendar: .current)
                    .map { StatsStyle.compactNumber($0) } ?? "–",
                caption: "open, 7-day avg"
            )
            StatTile(
                value: TabStatsSummary.recentMean(summary.openedByDay, days: Self.headlineDayCount, missingDaysAsZero: true, now: Date(), calendar: .current)
                    .map { StatsStyle.compactNumber($0) } ?? "–",
                caption: "opened a day"
            )
            StatTile(value: busiestLabel, caption: "busiest", tint: DS.Tint.warning)
        }
    }

    private var busiestLabel: String {
        let weekday = summary.busiestWeekday.map(StatsStyle.weekdayLabel)
        let hour = summary.busiestHour.map(StatsStyle.hourLabel)
        return [weekday, hour].compactMap { $0 }.joined(separator: " · ").nonEmpty ?? "–"
    }

    private var dayDomain: ClosedRange<Date> {
        let today = Calendar.current.startOfDay(for: Date())
        let start = Calendar.current.date(byAdding: .day, value: -(TabStatsSummary.chartedDayCount - 1), to: today) ?? today
        let end = Calendar.current.date(byAdding: .day, value: 1, to: today) ?? today
        return start...end
    }

    private var averageOpenChart: some View {
        Chart(summary.averageOpenByDay) { point in
            AreaMark(x: .value("Day", point.day, unit: .day), y: .value("Open tabs", point.value))
                .foregroundStyle(LinearGradient(
                    colors: [DS.Tint.action.opacity(0.28), DS.Tint.action.opacity(0.02)],
                    startPoint: .top, endPoint: .bottom
                ))
                .interpolationMethod(.monotone)
            LineMark(x: .value("Day", point.day, unit: .day), y: .value("Open tabs", point.value))
                .foregroundStyle(DS.Tint.action)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                .interpolationMethod(.monotone)
        }
        .chartXScale(domain: dayDomain)
        .modifier(DayAxes(domain: dayDomain))
        .frame(height: StatsStyle.chartHeight)
        .accessibilityLabel("Average open tabs per day")
    }

    private var openedPerDayChart: some View {
        Chart(summary.openedByDay) { point in
            BarMark(x: .value("Day", point.day, unit: .day), y: .value("Opened", point.value), width: .ratio(0.7))
                .foregroundStyle(DS.Tint.recent.gradient)
                .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
        }
        .chartXScale(domain: dayDomain)
        .modifier(DayAxes(domain: dayDomain))
        .frame(height: StatsStyle.compactChartHeight + 16)
        .accessibilityLabel("Tabs opened per day")
    }

    private var openedByHourChart: some View {
        Chart(summary.openedByHour) { point in
            BarMark(x: .value("Hour", Double(point.slot)), y: .value("Opened", point.value), width: .fixed(7))
                .foregroundStyle(point.slot == summary.busiestHour ? DS.Tint.warning : DS.Tint.warning.opacity(0.35))
                .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
        }
        .chartXScale(domain: -0.5...23.5)
        .chartXAxis {
            AxisMarks(values: [0.0, 6, 12, 18]) { value in
                AxisValueLabel {
                    if let hour = value.as(Double.self) { Text(StatsStyle.hourLabel(Int(hour))) }
                }
            }
        }
        .chartYAxis(.hidden)
        .frame(height: StatsStyle.compactChartHeight)
        .accessibilityLabel("Tabs opened by hour of day")
    }
}

/// Weekly date labels + light leading value grid, shared by the per-day charts.
private struct DayAxes: ViewModifier {
    let domain: ClosedRange<Date>

    /// A label every week from the first day, stopping short of the right edge so none truncates.
    private var labelDays: [Date] {
        stride(from: 0, to: TabStatsSummary.chartedDayCount - 5, by: 7).compactMap {
            Calendar.current.date(byAdding: .day, value: $0, to: domain.lowerBound)
        }
    }

    func body(content: Content) -> some View {
        content
            .chartXAxis {
                AxisMarks(values: labelDays) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day(), centered: false)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine().foregroundStyle(DS.Palette.hairline)
                    AxisValueLabel()
                }
            }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
