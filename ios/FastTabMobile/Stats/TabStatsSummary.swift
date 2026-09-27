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
    }

    /// `calendar` buckets the days (the phone's, whatever its calendar system). Each Mac's
    /// `yyyy-MM-dd` key is always a Gregorian date, placed on that date in the phone's time zone.
    ///
    /// Macs in different time zones meet by calendar date: Monday on each Mac is Monday here.
    /// Hours are each Mac's local hours, summed by index ("9 AM" means 9 AM on that Mac).
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
        let openedByWeekday = MetricQuery(metric: Metric.opened, interval: chartInterval, period: .weekday, reducer: .sum)
            .points(from: events, calendar: calendar)
            .compactMap { point -> SlotValue? in
                guard case .weekday(let weekday) = point.bucket else { return nil }
                return SlotValue(slot: weekday, value: point.value)
            }

        return TabStatsSummary(
            averageOpenByDay: perDay(Metric.averageOpen),
            openedByDay: perDay(Metric.opened),
            openedByWeekday: openedByWeekday,
            openedByHour: openedByHour(in: digests, chartInterval: chartInterval, calendar: calendar)
        )
    }

    /// Summed by hour index, not re-timestamped: the Mac's hour 9 stays 9 here, even across a
    /// daylight-saving day or a Mac in another time zone.
    private static func openedByHour(in digests: [SyncedTabStats], chartInterval: DateInterval, calendar: Calendar) -> [SlotValue] {
        var totals = Array(repeating: 0, count: TabDay.hoursPerDay)
        for tabDay in digests.flatMap(\.days) {
            guard let dayStart = dayStart(forKey: tabDay.day, calendar: calendar),
                  chartInterval.start <= dayStart, dayStart < chartInterval.end else { continue }
            for (hour, count) in tabDay.openedByHour.prefix(TabDay.hoursPerDay).enumerated() { totals[hour] += count }
        }
        guard totals.contains(where: { $0 > 0 }) else { return [] }
        return totals.enumerated().map { SlotValue(slot: $0.offset, value: Double($0.element)) }
    }

    private static func metricEvents(for digest: SyncedTabStats, calendar: Calendar) -> [MetricEvent] {
        digest.days.flatMap { tabDay -> [MetricEvent] in
            guard let dayStart = dayStart(forKey: tabDay.day, calendar: calendar) else { return [] }
            func event(_ metric: String, value: Double) -> MetricEvent {
                MetricEvent(timestamp: dayStart, subject: digest.deviceID, metric: metric, value: value)
            }
            return [event(Metric.averageOpen, value: tabDay.avgOpen), event(Metric.opened, value: Double(tabDay.opened))]
        }
    }

    // MARK: - Day keys

    /// Start of the Gregorian date `key` (`yyyy-MM-dd`, as the Mac writes it) in `calendar`'s
    /// time zone. Never read with `calendar` itself: on a Buddhist-calendar phone "2026" would be
    /// the Buddhist year 2026, five centuries back.
    static func dayStart(forKey key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let noonComponents = DateComponents(year: year, month: month, day: day, hour: 12)
        // Rejects impossible dates (2026-02-30) rather than rolling them into March.
        guard noonComponents.isValidDate(in: gregorian), let noon = gregorian.date(from: noonComponents) else { return nil }
        // From noon: in a zone whose clocks skip midnight, the day starts at 1 AM, not the day before.
        return calendar.startOfDay(for: noon)
    }

    /// Inverse of `dayStart(forKey:calendar:)`: the Gregorian `yyyy-MM-dd` of `date` in
    /// `calendar`'s time zone.
    static func dayKey(for date: Date, calendar: Calendar) -> String {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let parts = gregorian.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
