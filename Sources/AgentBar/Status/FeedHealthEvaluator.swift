import Foundation

/// Decides whether the dashboard's feeds are trustworthy enough to show
/// statuses. A feed the list depends on being dead must read as "down", never
/// as an empty, calm list.
enum FeedHealthEvaluator {
    /// Feeds whose loss makes agent statuses wrong:
    /// - `herdr`: the list of panes itself (no herdr, no agents),
    /// - `hookCache`: authoritative for "working",
    /// - `paneScreen`: authoritative for needs-you vs finished.
    /// The other feeds (board, paneTick, gitHealth, workItems) only add extras.
    static let essentialFeedNames = ["hookCache", "herdr", "paneScreen"]

    /// The delivery board only feeds Ended rows and unpushed markers.
    static let boardFeedName = "board"

    /// A feed is stale once its last success is older than this many refresh
    /// intervals. Same 3x budget the dashboard uses for its own "broken" alarm.
    static let staleAfterRefreshIntervals = 3.0

    /// First problem found among the essential feeds, as display text; nil if all healthy.
    static func firstProblem(in feeds: [String: DashboardFeed]) -> String? {
        for name in essentialFeedNames {
            if let problem = problem(withFeed: feeds[name], named: name) { return problem }
        }
        return nil
    }

    static func boardIsCurrent(in feeds: [String: DashboardFeed]) -> Bool {
        problem(withFeed: feeds[boardFeedName], named: boardFeedName) == nil
    }

    private static func problem(withFeed feed: DashboardFeed?, named name: String) -> String? {
        guard let feed else { return "the \(name) feed is missing" }
        if feed.broken == true {
            return "the \(name) feed is broken" + (feed.error.map { ": \($0)" } ?? "")
        }
        if feed.warming == true { return "the \(name) feed is still starting up" }
        guard let ageSec = feed.ageSec else { return "the \(name) feed has never reported" }
        if let refreshIntervalSec = feed.refreshIntervalSec,
           ageSec > refreshIntervalSec * staleAfterRefreshIntervals {
            return "the \(name) feed is stale (last update \(Int(ageSec))s ago)"
        }
        return nil
    }
}
