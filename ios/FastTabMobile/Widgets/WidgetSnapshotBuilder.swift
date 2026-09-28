import Foundation
import FastTabSync
import IndieMetrics

/// Pure functions that turn app state into the pieces of a `WidgetSnapshot`.
/// `WidgetSnapshotPublisher` feeds them; tests call them directly.
@MainActor
enum WidgetSnapshotBuilder {
    static let upNextLimit = 3
    static let recentTabLimit = 3
    /// An article read less than this far still counts as unread for "Up next".
    static let unreadProgressLimit = 0.05
    /// Daily totals kept in the snapshot: well past any realistic streak, still a small file.
    static let readingHistoryDays = 400

    /// Newest saved links the reader has not started, in the Read tab's order.
    /// `recentItems` is `RecentAddedProvider.items` (newest first).
    static func upNext(from recentItems: [RecentAddedItem], progress: (URL) -> Double) -> [WidgetSnapshot.Link] {
        recentItems
            .filter { progress($0.url) < unreadProgressLimit }
            .prefix(upNextLimit)
            .map { link(title: $0.title, url: $0.url) }
    }

    /// Words read per day from the reading log (`ReadingMetric.words` events).
    static func reading(from events: [MetricEvent], dailyWordGoal: Int, now: Date, calendar: Calendar) -> WidgetSnapshot.Reading {
        let oldestDay = calendar.date(byAdding: .day, value: -readingHistoryDays, to: calendar.startOfDay(for: now)) ?? now
        var wordsByDay: [Date: Double] = [:]
        for event in events where event.metric == ReadingMetric.words && event.timestamp >= oldestDay {
            wordsByDay[calendar.startOfDay(for: event.timestamp), default: 0] += event.value
        }
        return WidgetSnapshot.Reading(dailyWordGoal: dailyWordGoal, wordsByDay: wordsByDay)
    }

    /// The Shuffle deck's top card, exactly as the app shows it.
    static func shuffle(from topCard: RandomCardItem, thumbnailFileName: String?) -> WidgetSnapshot.Shuffle {
        var highlightID: String?
        if case .highlight(let highlight) = topCard.source { highlightID = highlight.id }
        return WidgetSnapshot.Shuffle(
            item: link(title: topCard.title, url: topCard.url),
            badge: topCard.source.badgeText,
            highlightID: highlightID,
            thumbnailFileName: thumbnailFileName
        )
    }

    /// Thumbnail file for a card, stable per card so the widget can tell whether it matches.
    static func thumbnailFileName(for card: RandomCardItem) -> String {
        let safe = card.id.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" }
        return "shuffle_\(String(safe).suffix(80)).jpg"
    }

    /// Open tabs across every synced Mac, most recently active first.
    static func openTabs(from tabs: [SyncedTab]) -> WidgetSnapshot.OpenTabs {
        let webTabs = tabs.compactMap { tab -> (SyncedTab, URL)? in
            guard let url = URL(string: tab.url), url.scheme?.hasPrefix("http") == true else { return nil }
            return (tab, url)
        }
        let recent = webTabs
            .sorted { $0.0.timestamp > $1.0.timestamp }
            .prefix(recentTabLimit)
            .map { link(title: $0.0.title, url: $0.1) }
        return WidgetSnapshot.OpenTabs(totalCount: tabs.count, recent: recent)
    }

    static func link(title: String, url: URL) -> WidgetSnapshot.Link {
        let domain = ReadingStatsRecorder.displayHost(of: url) ?? url.absoluteString
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return WidgetSnapshot.Link(title: trimmed.isEmpty ? domain : trimmed, url: url, domain: domain)
    }
}
