import Foundation
import FastTabSync
import IndieMetrics

/// Chart-ready tab activity summed across every Mac's `SyncedTabStats` digest.
///
/// Each Mac's `TabDay`s become metric events (subject = the Mac), and IndieMetrics' `.sum`
/// adds the Macs together per bucket: two Macs with 20 and 30 tabs open are 50 open tabs.
struct TabStatsSummary: Equatable {
    struct DayValue: Equatable, Identifiable {
        let day: Date
        let value: Double
        var id: Date { day }
    }

    struct SlotValue: Equatable, Identifiable {
        /// Hour 0...23 or `Calendar` weekday 1...7.
        let slot: Int
        let value: Double
        var id: Int { slot }
    }

    /// Days charted.
    static let chartedDayCount = 30

    /// Mean tabs open at once, per day.
    var averageOpenByDay: [DayValue] = []
    var openedByDay: [DayValue] = []
    /// Tabs opened per weekday / hour of day, over the charted days.
    var openedByWeekday: [SlotValue] = []
    var openedByHour: [SlotValue] = []

    static let empty = TabStatsSummary()
    var isEmpty: Bool { averageOpenByDay.isEmpty && openedByDay.isEmpty }

    var busiestWeekday: Int? { openedByWeekday.filter { $0.value > 0 }.max { $0.value < $1.value }?.slot }
    var busiestHour: Int? { openedByHour.filter { $0.value > 0 }.max { $0.value < $1.value }?.slot }

    /// Mean per day over the last `days` complete days (today is partial, so left out). Falls
    /// back to today alone when it is the only day there is.
    ///
    /// - `missingDaysAsZero`: true for counts (no data = nothing opened); false for levels like
    ///   open tabs, where no data means the Mac was off, not that it had zero tabs. Counts skip
    ///   days before the first data point, so a Mac that started reporting yesterday is not
    ///   averaged against a week of zeros.
    static func recentMean(
        _ values: [DayValue], days: Int, missingDaysAsZero: Bool, now: Date, calendar: Calendar
    ) -> Double? {
        guard let firstDay = values.first?.day else { return nil }
        let today = calendar.startOfDay(for: now)
        let rangeStart = max(firstDay, calendar.date(byAdding: .day, value: -days, to: today) ?? today)
        let completeDays = values.filter { $0.day >= rangeStart && $0.day < today }
        let total = completeDays.map(\.value).reduce(0, +)
        if missingDaysAsZero {
            let dayCount = calendar.dateComponents([.day], from: rangeStart, to: today).day ?? 0
            return dayCount > 0 ? total / Double(dayCount) : values.last?.value
        }
        return completeDays.isEmpty ? values.last?.value : total / Double(completeDays.count)
    }

    // MARK: - Building

    private enum Metric {
        static let averageOpen = "tabs.averageOpen"
        static let opened = "tabs.opened"
        static let openedInHour = "tabs.openedInHour"
    }

    /// `calendar` places each digest's `yyyy-MM-dd` days; the phone's calendar, so a day reads
    /// as the same date the Mac wrote.
    static func make(from digests: [SyncedTabStats], now: Date, calendar: Calendar) -> TabStatsSummary {
        let events = digests.flatMap { metricEvents(for: $0, calendar: calendar) }
        guard !events.isEmpty else { return .empty }
        let today = calendar.startOfDay(for: now)
        let chartStart = calendar.date(byAdding: .day, value: -(chartedDayCount - 1), to: today) ?? today
        let chartEnd = calendar.date(byAdding: .day, value: 1, to: today) ?? now
        let chartInterval = DateInterval(start: chartStart, end: chartEnd)

        func perDay(_ metric: String) -> [DayValue] {
            MetricQuery(metric: metric, interval: chartInterval, period: .day, reducer: .sum)
                .points(from: events, calendar: calendar)
                .compactMap { point in point.bucket.startDate.map { DayValue(day: $0, value: point.value) } }
        }
        func perSlot(_ metric: String, period: MetricPeriod) -> [SlotValue] {
            MetricQuery(metric: metric, interval: chartInterval, period: period, reducer: .sum)
                .points(from: events, calendar: calendar)
                .compactMap { point in
                    switch point.bucket {
                    case .hourOfDay(let slot), .weekday(let slot): return SlotValue(slot: slot, value: point.value)
                    case .periodStart: return nil
                    }
                }
        }

        return TabStatsSummary(
            averageOpenByDay: perDay(Metric.averageOpen),
            openedByDay: perDay(Metric.opened),
            openedByWeekday: perSlot(Metric.opened, period: .weekday),
            openedByHour: perSlot(Metric.openedInHour, period: .hourOfDay)
        )
    }

    private static func metricEvents(for digest: SyncedTabStats, calendar: Calendar) -> [MetricEvent] {
        let dayParser = dayFormatter(calendar: calendar)
        return digest.days.flatMap { tabDay -> [MetricEvent] in
            guard let dayStart = dayParser.date(from: tabDay.day) else { return [] }
            func event(_ metric: String, at timestamp: Date = dayStart, value: Double) -> MetricEvent {
                MetricEvent(timestamp: timestamp, subject: digest.deviceID, metric: metric, value: value)
            }
            var events = [
                event(Metric.averageOpen, value: tabDay.avgOpen),
                event(Metric.opened, value: Double(tabDay.opened))
            ]
            for (hour, openedCount) in tabDay.openedByHour.enumerated() where openedCount > 0 {
                guard let hourStart = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: dayStart) else { continue }
                events.append(event(Metric.openedInHour, at: hourStart, value: Double(openedCount)))
            }
            return events
        }
    }

    private static func dayFormatter(calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}
