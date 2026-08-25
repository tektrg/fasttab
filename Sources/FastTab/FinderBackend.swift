import Foundation
import AppKit
import OSLog

/// Treats macOS Finder as a "browser" so its open windows surface in FastTab
/// alongside browser tabs. One row per Finder window; sub-tabs within a single
/// Finder window are not enumerated (Finder tabs aren't first-class AppleScript
/// objects). The window's POSIX target path is used as the "url", so the
/// existing copy-link action copies the folder path for free.
struct FinderBackend: BrowserBackend {
    let appName: String = "Finder"
    let bundleIdentifier: String = "com.apple.finder"
    /// Persistent path history. Recorded on every `fetchLiveTabs` observation;
    /// surfaced through `fetchRecentHistory` / `searchHistory` so the existing
    /// `@History` scope picks it up without special-casing.
    let historyStore: FinderHistoryStore

    init(historyStore: FinderHistoryStore = .shared) {
        self.historyStore = historyStore
    }

    private static let logger = Logger(subsystem: "com.trungluong.FastTab", category: "FinderBackend")

    func fetchLiveTabs(
        fetchStart: Date,
        activeTimes: inout [String: Date],
        currentFlowSourceAppBundleIdentifier: String?
    ) -> [BrowserSearchResult] {
        let script = """
        tell application "Finder"
            if not running then return ""
            set output to ""
            set theWindows to every Finder window
            set winCount to count of theWindows
            repeat with i from 1 to winCount
                try
                    set w to item i of theWindows
                    set t to target of w
                    set p to POSIX path of (t as alias)
                    set n to name of w
                    set output to output & (i as text) & "\(kFieldSep)" & p & "\(kFieldSep)" & n & "\(kRowSep)"
                end try
            end repeat
            return output
        end tell
        """

        guard let raw = runProcess(launchPath: "/usr/bin/osascript", arguments: ["-e", script]),
              !raw.isEmpty else {
            return []
        }

        let isCurrentFlow = (currentFlowSourceAppBundleIdentifier == bundleIdentifier)
        var results: [BrowserSearchResult] = []
        for row in raw.split(separator: Character(kRowSep), omittingEmptySubsequences: true) {
            let fields = row.split(separator: Character(kFieldSep), omittingEmptySubsequences: false)
            guard fields.count >= 3,
                  let windowIndex = Int(fields[0]) else { continue }
            let path = String(fields[1])
            let windowName = String(fields[2])
            guard !path.isEmpty else { continue }

            let title = (path as NSString).lastPathComponent
            let recencyKey = makeTabRecencyKey(
                browserName: appName,
                windowIndex: windowIndex,
                tabIndex: 0,
                url: path
            )
            // Mark the front-most Finder window as the current flow's active tab
            // when FastTab was opened from Finder, mirroring the browser behavior
            // (filtered out of empty-query top-K so it doesn't eat a slot).
            let isFrontActive = isCurrentFlow && windowIndex == 1
            // Mirror ChromiumBackend timestamp policy: only the *current-flow*
            // front window counts as "now"; everything else falls back to its
            // stored active time, or epoch when never used. Defaulting to
            // fetchStart here makes every Finder window dominate the empty-query
            // top-K, which is the bug we're fixing.
            let storedTime = activeTimes[recencyKey]
            let timestamp: Date = {
                if isFrontActive { return fetchStart }
                return storedTime ?? Date(timeIntervalSince1970: 0)
            }()
            if isFrontActive {
                activeTimes[recencyKey] = fetchStart
            }

            results.append(BrowserSearchResult(
                title: title.isEmpty ? path : title,
                url: path,
                browserName: appName,
                type: .tab,
                timestamp: timestamp,
                windowIndex: windowIndex,
                tabIndex: 0,
                windowName: windowName,
                isCurrentFlowActiveTab: isFrontActive
            ))

            // Save every observed path into Finder-history. The store throttles
            // its own disk writes — this is just an in-memory upsert in the
            // common case.
            historyStore.record(path: path, at: isFrontActive ? fetchStart : (storedTime ?? fetchStart))
        }
        return results
    }

    func pollActiveTabKeys() -> [String] { [] }

    func fetchAllBookmarks() -> [BrowserSearchResult] { [] }

    func fetchRecentHistory(perBrowserLimit: Int) -> [BrowserSearchResult] {
        let entries = historyStore.snapshot()
            .sorted { $0.lastVisit > $1.lastVisit }
            .prefix(max(0, perBrowserLimit))
        return entries.map(makeHistoryResult)
    }

    func searchHistory(query: String, limit: Int) -> [BrowserSearchResult] {
        searchHistory(query: query, limit: limit, since: nil, before: nil)
    }

    func searchHistory(query: String, limit: Int, since: Date?, before: Date?) -> [BrowserSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let snapshot = historyStore.snapshot()
        let matches: [FinderHistoryEntry]
        if trimmed.isEmpty {
            matches = snapshot.filter { entry in
                if let since, entry.lastVisit < since { return false }
                if let before, entry.lastVisit >= before { return false }
                return true
            }
        } else {
            // Same word-by-word, accent-insensitive rule as tab/bookmark search
            // so file results don't behave differently from browser results.
            // Fold the query once rather than per snapshot entry — this runs
            // over the whole Finder history on every keystroke.
            let queryWords = searchWords(in: trimmed)
            matches = snapshot.filter {
                if let since, $0.lastVisit < since { return false }
                if let before, $0.lastVisit >= before { return false }
                return foldedKeys(
                    [foldForMatching($0.basename), foldForMatching($0.path)],
                    containAllWordsOf: queryWords
                )
            }
        }
        return matches
            .sorted { $0.lastVisit > $1.lastVisit }
            .prefix(max(0, limit))
            .map(makeHistoryResult)
    }

    private func makeHistoryResult(from entry: FinderHistoryEntry) -> BrowserSearchResult {
        BrowserSearchResult(
            title: entry.basename.isEmpty ? entry.path : entry.basename,
            url: entry.path,
            browserName: appName,
            type: .history,
            timestamp: entry.lastVisit
        )
    }

    func fetchFaviconData(pageURL: String) -> Data? { nil }

    func activateTab(_ result: BrowserSearchResult) {
        // Prefer window-index addressing (O(1), no alias resolution). If the
        // index is stale, fall back to path matching so we still do something
        // useful instead of failing silently.
        let path = appleScriptQuoted(result.url)
        let script: String
        if let windowIndex = result.windowIndex, windowIndex >= 1 {
            script = """
            tell application "Finder"
                activate
                try
                    set index of window \(windowIndex) to 1
                on error
                    set theWindows to every Finder window
                    set winCount to count of theWindows
                    repeat with i from 1 to winCount
                        try
                            set w to item i of theWindows
                            set t to target of w
                            if POSIX path of (t as alias) is "\(path)" then
                                set index of w to 1
                                exit repeat
                            end if
                        end try
                    end repeat
                end try
            end tell
            """
        } else {
            script = """
            tell application "Finder"
                activate
                set theWindows to every Finder window
                set winCount to count of theWindows
                repeat with i from 1 to winCount
                    try
                        set w to item i of theWindows
                        set t to target of w
                        if POSIX path of (t as alias) is "\(path)" then
                            set index of w to 1
                            exit repeat
                        end if
                    end try
                end repeat
            end tell
            """
        }
        runAppleScript(script, logger: Self.logger, action: "activateTab")
    }

    func closeTab(_ result: BrowserSearchResult) {
        _ = closeTabWithResult(result, allowPositionalFallback: true)
    }

    /// Mirrors ChromiumBackend/SafariBackend's contract: `allowPositionalFallback:
    /// true` (local swipe-to-close) trusts the last-known window index and avoids
    /// `target of w as alias`, which can stall on sleeping NAS / unmounted shares.
    /// `false` (remote close from iOS, via `SyncService+CommandDelivery`) instead
    /// verifies by path across every window and refuses an ambiguous match —
    /// without this override, remote Finder-window closes silently no-op through
    /// the `BrowserBackend` protocol's default `closeTabWithResult`, which always
    /// returns `.notFound` and never runs any AppleScript at all.
    func closeTabWithResult(_ result: BrowserSearchResult, allowPositionalFallback: Bool) -> TabCloseResult {
        let path = appleScriptQuoted(result.url)
        let script: String
        if allowPositionalFallback {
            if let windowIndex = result.windowIndex, windowIndex >= 1 {
                script = """
                tell application "Finder"
                    if not running then return "not_found"
                    try
                        close window \(windowIndex)
                        return "closed"
                    end try
                    return "not_found"
                end tell
                """
            } else {
                script = """
                tell application "Finder"
                    if not running then return "not_found"
                    set targetPath to "\(path)"
                    try
                        set theWindows to every Finder window
                        set winCount to count of theWindows
                        repeat with i from 1 to winCount
                            try
                                set w to item i of theWindows
                                set t to target of w
                                if POSIX path of (t as alias) is targetPath then
                                    close w
                                    return "closed"
                                end if
                            end try
                        end repeat
                    end try
                    return "not_found"
                end tell
                """
            }
        } else {
            script = """
            tell application "Finder"
                if not running then return "not_found"
                set targetPath to "\(path)"
                set matchCount to 0
                try
                    set theWindows to every Finder window
                    set winCount to count of theWindows
                    repeat with i from 1 to winCount
                        try
                            set w to item i of theWindows
                            set t to target of w
                            if POSIX path of (t as alias) is targetPath then
                                set matchCount to matchCount + 1
                                set matchedWindow to w
                            end if
                        end try
                    end repeat
                end try
                if matchCount is equal to 0 then
                    return "not_found"
                else if matchCount is greater than 1 then
                    return "refused:ambiguous"
                else
                    try
                        close matchedWindow
                        return "closed"
                    end try
                    return "not_found"
                end if
            end tell
            """
        }

        Self.logger.info("closeTabWithResult: allowPositional=\(allowPositionalFallback) title='\(result.title, privacy: .public)' path='\(result.url, privacy: .public)'")
        let output = runProcess(launchPath: "/usr/bin/osascript", arguments: ["-e", script], timeoutSeconds: 8)
        switch output {
        case "closed":
            return .closed
        case "refused:ambiguous":
            return .refused("Ambiguous window path: multiple Finder windows open on the same folder")
        default:
            return .notFound
        }
    }

    func openURL(_ result: BrowserSearchResult) {
        // History-row activation: open the path in a new Finder window via
        // NSWorkspace (no AppleScript). The system handles a missing path with
        // its own error — we don't pre-validate (would add I/O to the open
        // path and the design call was "let Finder/system handle the error").
        if result.type == .history {
            let url = URL(fileURLWithPath: result.url)
            NSWorkspace.shared.open(url)
            return
        }
        activateTab(result)
    }

    func deleteBookmark(_ result: BrowserSearchResult) {}

    func deleteHistoryItem(_ result: BrowserSearchResult) {
        historyStore.remove(path: result.url)
    }
}
