import Foundation

/// "Close the ring" state for one day: words read against the daily word goal.
struct ReadingRingDay: Equatable, Identifiable {
    let dayStart: Date
    let words: Double
    let goal: Int

    var id: Date { dayStart }
    /// 0...1, the drawn arc. Past the goal the ring just stays closed.
    var fraction: Double { goal > 0 ? min(1, max(0, words / Double(goal))) : 0 }
    var isClosed: Bool { goal > 0 && words >= Double(goal) }
}

/// Ring values derived from `WidgetSnapshot.Reading` for a given moment. Shared by the widget
/// (renders it) and the app (tests it), so "today" is always the render date, not the write date.
struct ReadingRingProgress: Equatable {
    let today: ReadingRingDay
    /// Oldest first, ending with today.
    let lastSevenDays: [ReadingRingDay]
    /// Consecutive closed days ending today, or ending yesterday while today is still open
    /// (an unfinished today does not break the streak until the day is over).
    let streak: Int

    static let weekLength = 7

    static func make(from reading: WidgetSnapshot.Reading, now: Date, calendar: Calendar) -> ReadingRingProgress {
        let todayStart = calendar.startOfDay(for: now)
        let wordsByDay = Dictionary(
            reading.wordsByDay.map { (calendar.startOfDay(for: $0.key), $0.value) },
            uniquingKeysWith: +
        )
        func day(_ offset: Int) -> ReadingRingDay {
            let start = calendar.date(byAdding: .day, value: -offset, to: todayStart) ?? todayStart
            return ReadingRingDay(dayStart: start, words: wordsByDay[start] ?? 0, goal: reading.dailyWordGoal)
        }

        let today = day(0)
        var streak = 0
        var offset = today.isClosed ? 0 : 1
        while offset <= wordsByDay.count, day(offset).isClosed {
            streak += 1
            offset += 1
        }

        return ReadingRingProgress(
            today: today,
            lastSevenDays: (0..<weekLength).reversed().map(day),
            streak: streak
        )
    }
}
