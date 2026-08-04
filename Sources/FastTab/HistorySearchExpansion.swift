import Foundation

struct HistorySearchWindow: Equatable, Sendable {
    let since: Date?
    let before: Date?
}

enum HistorySearchExpansion {
    static let minimumHistoryResults = 5
    static let budgetSeconds: TimeInterval = 1.0

    private static let day: TimeInterval = 86_400
    private static let recentBoundaries: [TimeInterval] = [
        7 * day,
        30 * day,
        90 * day,
        365 * day
    ]

    static func windows(now: Date, since scopeSince: Date?, before scopeBefore: Date?) -> [HistorySearchWindow] {
        var windows: [HistorySearchWindow] = []
        var newestBoundary: Date?

        for age in recentBoundaries {
            let olderBoundary = now.addingTimeInterval(-age)
            appendWindow(
                since: olderBoundary,
                before: newestBoundary,
                scopeSince: scopeSince,
                scopeBefore: scopeBefore,
                to: &windows
            )
            newestBoundary = olderBoundary
        }

        appendWindow(
            since: nil,
            before: newestBoundary,
            scopeSince: scopeSince,
            scopeBefore: scopeBefore,
            to: &windows
        )

        return windows
    }

    static func search(
        query: String,
        backends: [any BrowserBackend],
        perBackendLimit: Int,
        since: Date?,
        before: Date?,
        minimumResults: Int = minimumHistoryResults,
        budgetSeconds: TimeInterval = budgetSeconds
    ) async -> [BrowserSearchResult] {
        let deadline = Date().addingTimeInterval(budgetSeconds)
        let windows = windows(now: Date(), since: since, before: before)
        var deduped: [String: BrowserSearchResult] = [:]

        for window in windows {
            let remainingSeconds = deadline.timeIntervalSinceNow
            if deduped.count >= minimumResults || remainingSeconds <= 0 {
                break
            }

            let chunk = await searchWindow(
                query: query,
                backends: backends,
                perBackendLimit: perBackendLimit,
                window: window,
                timeoutSeconds: remainingSeconds
            )
            merge(chunk, into: &deduped)
        }

        return deduped.values
            .sorted { $0.timestamp > $1.timestamp }
            .map { $0 }
    }

    private static func appendWindow(
        since candidateSince: Date?,
        before candidateBefore: Date?,
        scopeSince: Date?,
        scopeBefore: Date?,
        to windows: inout [HistorySearchWindow]
    ) {
        let since = later(candidateSince, scopeSince)
        let before = earlier(candidateBefore, scopeBefore)

        if let since, let before, since >= before {
            return
        }
        windows.append(HistorySearchWindow(since: since, before: before))
    }

    private static func searchWindow(
        query: String,
        backends: [any BrowserBackend],
        perBackendLimit: Int,
        window: HistorySearchWindow,
        timeoutSeconds: TimeInterval
    ) async -> [BrowserSearchResult] {
        await withTaskGroup(of: [BrowserSearchResult].self) { group in
            for backend in backends {
                group.addTask {
                    backend.searchHistory(
                        query: query,
                        limit: perBackendLimit,
                        since: window.since,
                        before: window.before,
                        timeoutSeconds: max(0.05, timeoutSeconds)
                    )
                }
            }

            var all: [BrowserSearchResult] = []
            for await chunk in group {
                all.append(contentsOf: chunk)
            }
            return all
        }
    }

    private static func merge(_ results: [BrowserSearchResult], into deduped: inout [String: BrowserSearchResult]) {
        for result in results {
            let key = [
                result.browserName,
                result.profileName ?? "",
                result.url
            ].joined(separator: "|")

            if let existing = deduped[key], existing.timestamp >= result.timestamp {
                continue
            }
            deduped[key] = result
        }
    }

    private static func later(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case (.none, .none):
            return nil
        case (.some(let lhs), .none):
            return lhs
        case (.none, .some(let rhs)):
            return rhs
        case (.some(let lhs), .some(let rhs)):
            return max(lhs, rhs)
        }
    }

    private static func earlier(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case (.none, .none):
            return nil
        case (.some(let lhs), .none):
            return lhs
        case (.none, .some(let rhs)):
            return rhs
        case (.some(let lhs), .some(let rhs)):
            return min(lhs, rhs)
        }
    }
}
