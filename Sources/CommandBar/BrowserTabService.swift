import Foundation
import AppKit
import OSLog

// ASCII control characters guaranteed not to appear in URLs or page titles.
private let kFieldSep = "\u{1F}" // unit separator
private let kRowSep   = "\u{1C}" // file separator

// Key for lastActiveTimes: URL-based (no tab index) so it survives tab reordering.
private func activeKey(appName: String, url: String) -> String {
    "\(appName)|\(url)"
}

private func appleScriptQuoted(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}

private struct ChromiumBrowser: Sendable {
    let appName: String
    let supportDirectory: String
}

private struct ChromiumProfile: Sendable {
    let browser: ChromiumBrowser
    let name: String
    let directoryURL: URL

    var bookmarksURL: URL { directoryURL.appendingPathComponent("Bookmarks") }
    var historyURL: URL { directoryURL.appendingPathComponent("History") }
}

@MainActor
class BrowserTabService: ObservableObject {
    @Published var results: [BrowserSearchResult] = []
    @Published var isLoading: Bool = false

    private let logger = Logger(subsystem: "com.trungluong.CommandBar", category: "BrowserTabService")
    private var lastActiveTimes: [String: Date] = [:]
    private var fetchTask: Task<Void, Never>?

    private let browsers: [ChromiumBrowser] = [
        ChromiumBrowser(appName: "Google Chrome", supportDirectory: "~/Library/Application Support/Google/Chrome"),
        ChromiumBrowser(appName: "Microsoft Edge", supportDirectory: "~/Library/Application Support/Microsoft Edge")
    ]

    func fetchResults(matching query: String = "") {
        fetchTask?.cancel()
        logger.info("Starting browser result fetch.")
        isLoading = true

        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let cachedTimes = self.lastActiveTimes
        let browsers = self.browsers

        fetchTask = Task.detached(priority: .userInitiated) { [weak self] in
            var updatedTimes = cachedTimes
            let fetchStart = Date()
            var combinedResults: [BrowserSearchResult] = []

            for browser in browsers {
                if Task.isCancelled { break }

                let tabResults = Self.fetchTabResults(for: browser, fetchStart: fetchStart, activeTimes: &updatedTimes)
                if normalizedQuery.isEmpty {
                    combinedResults.append(contentsOf: tabResults)
                    continue
                }

                combinedResults.append(contentsOf: tabResults.filter { $0.matches(query: normalizedQuery) })
                combinedResults.append(contentsOf: Self.fetchBookmarkResults(for: browser, query: normalizedQuery))
                combinedResults.append(contentsOf: Self.fetchHistoryResults(for: browser, query: normalizedQuery))
            }

            let sortedResults = sortBrowserSearchResults(combinedResults)

            guard !Task.isCancelled else {
                await MainActor.run { self?.isLoading = false }
                return
            }

            await MainActor.run {
                guard let self, !Task.isCancelled else { return }
                self.logger.info("Browser result fetch complete. resultCount=\(sortedResults.count)")
                self.lastActiveTimes = updatedTimes
                self.results = sortedResults
                self.isLoading = false
            }
        }
    }

    func activate(_ result: BrowserSearchResult) {
        switch result.type {
        case .tab:
            activateTab(result)
        case .bookmark, .history:
            openURL(result)
        }
    }

    private func activateTab(_ result: BrowserSearchResult) {
        lastActiveTimes[activeKey(appName: result.browserName, url: result.url)] = Date()

        let safeURL = appleScriptQuoted(result.url)
        let script = """
        tell application "\(result.browserName)"
            activate
            set targetURL to "\(safeURL)"
            set foundMatch to false
            try
                repeat with w in windows
                    set tabURLs to URL of every tab of w
                    repeat with i from 1 to count of tabURLs
                        if (item i of tabURLs) is equal to targetURL then
                            set index of w to 1
                            set active tab index of window 1 to i
                            set foundMatch to true
                            exit repeat
                        end if
                    end repeat
                    if foundMatch then exit repeat
                end repeat
            end try
            if foundMatch is false then
                try
                    set index of window \(result.windowIndex ?? 1) to 1
                    set active tab index of window 1 to \(result.tabIndex ?? 1)
                end try
            end if
        end tell
        """

        logger.info("activateTab: app=\(result.browserName, privacy: .public) title='\(result.title, privacy: .public)' url='\(result.url, privacy: .public)'")
        runAppleScript(script, logger: logger, action: "activateTab")
    }

    private func openURL(_ result: BrowserSearchResult) {
        let safeURL = appleScriptQuoted(result.url)
        let script = """
        tell application "\(result.browserName)"
            activate
            open location "\(safeURL)"
        end tell
        """

        logger.info("openURL: app=\(result.browserName, privacy: .public) type=\(result.type.rawValue, privacy: .public) url='\(result.url, privacy: .public)'")
        runAppleScript(script, logger: logger, action: "openURL")
    }

    private func runAppleScript(_ script: String, logger: Logger, action: String) {
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", script]
        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus != 0 {
                logger.error("\(action, privacy: .public): osascript exited with status \(task.terminationStatus)")
            }
        } catch {
            logger.error("\(action, privacy: .public): failed to run osascript: \(String(describing: error), privacy: .public)")
        }
    }

    private nonisolated static func fetchTabResults(
        for browser: ChromiumBrowser,
        fetchStart: Date,
        activeTimes: inout [String: Date]
    ) -> [BrowserSearchResult] {
        let script = """
        tell application "\(browser.appName)"
            if it is not running then return ""
            set fieldSep to (ASCII character 31)
            set rowSep to (ASCII character 28)
            set tabData to ""
            try
                set winCount to count of windows
                repeat with w from 1 to winCount
                    set activeTabIndex to active tab index of window w
                    set tabTitles to title of every tab of window w
                    set tabURLs to URL of every tab of window w
                    repeat with t from 1 to count of tabTitles
                        set isActive to (t is equal to activeTabIndex and w is equal to 1) as string
                        set rowData to "\(browser.appName)" & fieldSep & w & fieldSep & t & fieldSep & (item t of tabTitles) & fieldSep & (item t of tabURLs) & fieldSep & isActive
                        if tabData is "" then
                            set tabData to rowData
                        else
                            set tabData to tabData & rowSep & rowData
                        end if
                    end repeat
                end repeat
            on error
                return ""
            end try
            return tabData
        end tell
        """

        guard let output = runProcess(launchPath: "/usr/bin/osascript", arguments: ["-e", script]), !output.isEmpty else {
            return []
        }

        var newResults: [BrowserSearchResult] = []
        let rows = output.components(separatedBy: kRowSep)
        for row in rows where !row.isEmpty {
            let parts = row.components(separatedBy: kFieldSep)
            guard parts.count >= 6 else { continue }

            let appName = parts[0]
            let winIdx = Int(parts[1]) ?? 1
            let tabIdx = Int(parts[2]) ?? 1
            let title = parts[3]
            let url = parts[4]
            let isActive = parts[5] == "true"
            let key = activeKey(appName: appName, url: url)
            let timestamp = isActive ? fetchStart : (activeTimes[key] ?? Date(timeIntervalSince1970: 0))

            if isActive {
                activeTimes[key] = fetchStart
            }

            newResults.append(
                BrowserSearchResult(
                    title: title,
                    url: url,
                    browserName: appName,
                    type: .tab,
                    timestamp: timestamp,
                    windowIndex: winIdx,
                    tabIndex: tabIdx
                )
            )
        }

        return newResults
    }

    private nonisolated static func fetchBookmarkResults(for browser: ChromiumBrowser, query: String) -> [BrowserSearchResult] {
        guard !query.isEmpty else { return [] }

        let profiles = chromiumProfiles(for: browser)
        var results: [BrowserSearchResult] = []

        for profile in profiles {
            guard let data = try? Data(contentsOf: profile.bookmarksURL),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let roots = root["roots"] as? [String: Any] else {
                continue
            }

            for value in roots.values {
                guard let node = value as? [String: Any] else { continue }
                collectBookmarkMatches(
                    from: node,
                    browserName: browser.appName,
                    profileName: profile.name,
                    query: query,
                    folderTrail: [],
                    results: &results
                )
            }
        }

        return results
    }

    private nonisolated static func collectBookmarkMatches(
        from node: [String: Any],
        browserName: String,
        profileName: String,
        query: String,
        folderTrail: [String],
        results: inout [BrowserSearchResult]
    ) {
        let type = node["type"] as? String
        let nodeName = (node["name"] as? String) ?? ""

        if type == "url" {
            let url = (node["url"] as? String) ?? ""
            if matchesSearch(text: nodeName, url: url, query: query) {
                results.append(
                    BrowserSearchResult(
                        title: nodeName.isEmpty ? url : nodeName,
                        url: url,
                        browserName: browserName,
                        type: .bookmark,
                        timestamp: chromiumDate(from: node["date_added"] as? String) ?? Date(timeIntervalSince1970: 0),
                        bookmarkID: node["id"] as? String,
                        profileName: profileName,
                        folderPath: folderTrail.joined(separator: " / ")
                    )
                )
            }
            return
        }

        let nextTrail = type == "folder" && !nodeName.isEmpty ? folderTrail + [nodeName] : folderTrail
        guard let children = node["children"] as? [[String: Any]] else { return }
        for child in children {
            collectBookmarkMatches(
                from: child,
                browserName: browserName,
                profileName: profileName,
                query: query,
                folderTrail: nextTrail,
                results: &results
            )
        }
    }

    private nonisolated static func fetchHistoryResults(for browser: ChromiumBrowser, query: String, perBrowserLimit: Int = 20) -> [BrowserSearchResult] {
        guard !query.isEmpty else { return [] }

        var dedupedByURL: [String: BrowserSearchResult] = [:]

        for profile in chromiumProfiles(for: browser) {
            guard FileManager.default.fileExists(atPath: profile.historyURL.path) else { continue }
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

            do {
                try FileManager.default.copyItem(at: profile.historyURL, to: tempURL)
                let escapedQuery = sqlLikeEscaped(query.lowercased())
                let sql = """
                SELECT title, url, last_visit_time
                FROM urls
                WHERE url IS NOT NULL
                  AND url != ''
                  AND (
                    lower(COALESCE(title, '')) LIKE '%\(escapedQuery)%'
                    OR lower(url) LIKE '%\(escapedQuery)%'
                  )
                ORDER BY last_visit_time DESC
                LIMIT 60;
                """

                guard let output = runProcess(
                    launchPath: "/usr/bin/sqlite3",
                    arguments: ["-separator", kFieldSep, tempURL.path, sql]
                ) else {
                    try? FileManager.default.removeItem(at: tempURL)
                    continue
                }

                let rows = output.split(separator: "\n", omittingEmptySubsequences: true)
                for row in rows {
                    let parts = String(row).components(separatedBy: kFieldSep)
                    guard parts.count >= 3 else { continue }

                    let title = parts[0].isEmpty ? parts[1] : parts[0]
                    let url = parts[1]
                    let timestamp = chromiumDate(fromSQLiteValue: parts[2]) ?? Date(timeIntervalSince1970: 0)
                    let candidate = BrowserSearchResult(
                        title: title,
                        url: url,
                        browserName: browser.appName,
                        type: .history,
                        timestamp: timestamp,
                        profileName: profile.name
                    )
                    let key = "\(browser.appName)|\(url)"
                    if let existing = dedupedByURL[key], existing.timestamp >= candidate.timestamp {
                        continue
                    }
                    dedupedByURL[key] = candidate
                }

                try? FileManager.default.removeItem(at: tempURL)
            } catch {
                try? FileManager.default.removeItem(at: tempURL)
            }
        }

        return dedupedByURL.values
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(perBrowserLimit)
            .map { $0 }
    }

    private nonisolated static func chromiumProfiles(for browser: ChromiumBrowser) -> [ChromiumProfile] {
        let basePath = (browser.supportDirectory as NSString).expandingTildeInPath
        let baseURL = URL(fileURLWithPath: basePath, isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: baseURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return urls
            .filter { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            .compactMap { url in
                let bookmarksExists = FileManager.default.fileExists(atPath: url.appendingPathComponent("Bookmarks").path)
                let historyExists = FileManager.default.fileExists(atPath: url.appendingPathComponent("History").path)
                guard bookmarksExists || historyExists else { return nil }
                return ChromiumProfile(browser: browser, name: url.lastPathComponent, directoryURL: url)
            }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    private nonisolated static func matchesSearch(text: String, url: String, query: String) -> Bool {
        text.localizedCaseInsensitiveContains(query) || url.localizedCaseInsensitiveContains(query)
    }

    private nonisolated static func chromiumDate(from rawValue: String?) -> Date? {
        guard let rawValue, let microseconds = Double(rawValue) else { return nil }
        return Date(timeIntervalSince1970: (microseconds / 1_000_000) - 11_644_473_600)
    }

    private nonisolated static func chromiumDate(fromSQLiteValue rawValue: String) -> Date? {
        guard let microseconds = Double(rawValue) else { return nil }
        return Date(timeIntervalSince1970: (microseconds / 1_000_000) - 11_644_473_600)
    }

    private nonisolated static func sqlLikeEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    private nonisolated static func runProcess(launchPath: String, arguments: [String]) -> String? {
        let task = Process()
        task.launchPath = launchPath
        task.arguments = arguments

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }
}
