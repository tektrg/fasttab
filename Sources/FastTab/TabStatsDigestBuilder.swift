import Foundation
import IndieMetrics
import FastTabSync

/// Pure: metric events from `TabActivityRecorder` -> the per-day digest the
/// Mac publishes as `SyncedTabStats`. Days are cut in `calendar`'s time zone
/// (the Mac's), and only days with at least one event appear.
enum TabStatsDigestBuilder {
    static func days(
        from events: [MetricEvent],
        calendar: Calendar,
        now: Date,
        dayCount: Int = SyncedTabStats.retainedDayCount
    ) -> [TabDay] {
        let today = calendar.startOfDay(for: now)
        let firstDay = calendar.date(byAdding: .day, value: -(max(1, dayCount) - 1), to: today) ?? today
        // Ends just after `now`, so today's last gauge sample holds until now, not
        // into the future (the interval is half-open).
        let window = DateInterval(start: firstDay, end: max(firstDay, now).addingTimeInterval(1))

        func dailyValues(_ metric: String, _ reducer: MetricReducer) -> [Date: Double] {
            let points = MetricQuery(metric: metric, interval: window, period: .day, reducer: reducer)
                .points(from: events, calendar: calendar)
            return points.reduce(into: [:]) { values, point in
                if let dayStart = point.bucket.startDate { values[dayStart] = point.value }
            }
        }

        let opened = dailyValues(TabMetric.opened, .sum)
        let closed = dailyValues(TabMetric.closed, .sum)
        let avgOpen = dailyValues(TabMetric.openCount, .timeWeightedAverage(maxGap: TabMetric.gaugeMaxHold))
        let maxOpen = dailyValues(TabMetric.openCount, .max)
        let openedByHour = openedByHourPerDay(events: events, window: window, calendar: calendar)

        let activeDays = Set(opened.keys).union(closed.keys).union(avgOpen.keys).sorted()
        return activeDays.map { dayStart in
            TabDay(
                day: dayKey(dayStart, calendar: calendar),
                opened: Int(opened[dayStart] ?? 0),
                closed: Int(closed[dayStart] ?? 0),
                avgOpen: avgOpen[dayStart] ?? 0,
                maxOpen: Int(maxOpen[dayStart] ?? 0),
                openedByHour: openedByHour[dayStart] ?? []
            )
        }
    }

    /// `yyyy-MM-dd` in `calendar`, without a locale-sensitive formatter.
    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static func openedByHourPerDay(events: [MetricEvent], window: DateInterval, calendar: Calendar) -> [Date: [Int]] {
        let query = MetricQuery(
            metric: TabMetric.opened,
            interval: window,
            period: .day,
            grouping: .key { String(calendar.component(.hour, from: $0.timestamp)) },
            reducer: .sum
        )
        var hoursByDay: [Date: [Int]] = [:]
        for point in query.points(from: events, calendar: calendar) {
            guard let dayStart = point.bucket.startDate,
                  let hour = point.group.flatMap(Int.init),
                  (0..<TabDay.hoursPerDay).contains(hour) else { continue }
            hoursByDay[dayStart, default: Array(repeating: 0, count: TabDay.hoursPerDay)][hour] += Int(point.value)
        }
        return hoursByDay
    }
}
