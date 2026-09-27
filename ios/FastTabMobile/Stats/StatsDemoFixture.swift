#if DEBUG
import Foundation
import FastTabSync
import IndieMetrics

/// Made-up stats for screenshots and design review. Debug builds only, never written to disk.
/// Enable with the launch argument `-FastTabStatsDemo YES`.
enum StatsDemoFixture {
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "FastTabStatsDemo") }

    private static let articles: [(subject: String, topic: String, wordsPerWeek: Double)] = [
        ("https://demo.example/swift-concurrency", "Swift", 2_600),
        ("https://demo.example/llm-agents", "AI", 1_900),
        ("https://demo.example/typography", "Design", 1_100),
        ("https://demo.example/sleep-science", "Health", 700),
        ("https://demo.example/city-walks", "Travel", 350),
        ("https://demo.example/vinyl", "Music", 250)
    ]

    static let topicsByArticle = Dictionary(uniqueKeysWithValues: articles.map { ($0.subject, $0.topic) })

    static func readingEvents(now: Date) -> [MetricEvent] {
        var events: [MetricEvent] = []
        for week in 0..<8 {
            let weekEnergy = 0.55 + 0.45 * sin(Double(week) * 0.9 + 1)
            for (index, article) in articles.enumerated() {
                let timestamp = now.addingTimeInterval(-Double(week * 7 + index % 3) * 86_400)
                events.append(MetricEvent(
                    timestamp: timestamp, subject: article.subject, metric: ReadingMetric.words,
                    value: (article.wordsPerWeek * weekEnergy).rounded()
                ))
                if (week + index) % 3 == 0 {
                    events.append(MetricEvent(timestamp: timestamp, subject: article.subject, metric: ReadingMetric.finished))
                }
                if (week * 2 + index) % 4 == 0 {
                    events.append(MetricEvent(timestamp: timestamp, subject: article.subject, metric: ReadingMetric.highlight))
                }
            }
        }
        return events
    }

    static func tabDigests(now: Date, calendar: Calendar) -> [SyncedTabStats] {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        func days(scale: Double) -> [TabDay] {
            (0..<45).compactMap { daysAgo -> TabDay? in
                guard let date = calendar.date(byAdding: .day, value: -daysAgo, to: now) else { return nil }
                let weekday = calendar.component(.weekday, from: date)
                let isWeekend = weekday == 1 || weekday == 7
                let opened = Int((isWeekend ? 14 : 38 + 10 * sin(Double(daysAgo) * 0.7)) * scale)
                let hours = (0..<24).map { hour -> Int in
                    let workPeak = exp(-pow(Double(hour) - 10.5, 2) / 6) + 0.7 * exp(-pow(Double(hour) - 15, 2) / 5)
                    return Int(Double(opened) * workPeak / 2.2)
                }
                return TabDay(
                    day: formatter.string(from: date), opened: opened, closed: opened,
                    avgOpen: (isWeekend ? 18 : 31 + 6 * cos(Double(daysAgo) * 0.3)) * scale,
                    maxOpen: Int(48 * scale), openedByHour: hours
                )
            }
        }
        return [
            SyncedTabStats(deviceID: "demo-mac-pro", timeZoneID: calendar.timeZone.identifier, days: days(scale: 1)),
            SyncedTabStats(deviceID: "demo-mac-air", timeZoneID: calendar.timeZone.identifier, days: days(scale: 0.4))
        ]
    }
}
#endif
