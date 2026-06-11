import Foundation
import AppKit
import OSLog

struct ChromiumProfile: Sendable {
    let browserAppName: String
    let name: String
    let directoryURL: URL

    var bookmarksURL: URL { directoryURL.appendingPathComponent("Bookmarks") }
    var historyURL: URL { directoryURL.appendingPathComponent("History") }
    var faviconsURL: URL { directoryURL.appendingPathComponent("Favicons") }
}

struct ChromiumBackend: BrowserBackend {
    let appName: String
    let bundleIdentifier: String
    let supportDirectory: String

    private var logger: Logger {
        Logger(subsystem: "com.trungluong.FastTab", category: "ChromiumBackend")
    }

    // MARK: - Live tabs

    func fetchLiveTabs(
        fetchStart: Date,
        activeTimes: inout [String: Date],
        currentFlowSourceAppBundleIdentifier: String?
    ) -> [BrowserSearchResult] {
        let script = """
        tell application "\(appName)"
            if it is not running then return ""
            set fieldSep to (ASCII character 31)
            set rowSep to (ASCII character 28)
            set tabData to ""
            try
                set winCount to count of windows
                repeat with w from 1 to winCount
                    set activeTabIndex to active tab index of window w
                    set windowTitle to title of window w
                    set tabTitles to title of every tab of window w
                    set tabURLs to URL of every tab of window w
                    repeat with t from 1 to count of tabTitles
                        set isActive to (t is equal to activeTabIndex) as string
                        set rowData to "\(appName)" & fieldSep & w & fieldSep & t & fieldSep & (item t of tabTitles) & fieldSep & (item t of tabURLs) & fieldSep & isActive & fieldSep & windowTitle
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
        let activeTimesCount = activeTimes.count
        logger.info("recency-sort fetchLiveTabs start. browser='\(self.appName, privacy: .public)' activeTimesCount=\(activeTimesCount) rows=\(rows.count)")
        for row in rows where !row.isEmpty {
            let parts = row.components(separatedBy: kFieldSep)
            guard parts.count >= 7 else { continue }

            let appName = parts[0]
            let winIdx = Int(parts[1]) ?? 1
            let tabIdx = Int(parts[2]) ?? 1
            let title = parts[3]
            let url = parts[4]
            let isActive = parts[5] == "true"
            let windowName = parts[6]
            let hasMediaIndicator = browserWindowMediaIndicatorBelongsToTab(tabTitle: title, windowName: windowName)
            let key = makeTabRecencyKey(browserName: appName, windowIndex: winIdx, tabIndex: tabIdx, url: url)
            // Only the active tab of the FRONT window (winIdx == 1) of the
            // source browser is treated as "the tab the user is on" and
            // excluded from quick-open. Other windows' active tabs are fair
            // game for the recency-ordered top 5.
            // The tab is "currently being viewed" only when it is the active
            // tab of the front window AND its app is the frontmost app the
            // user activated FastTab from. Only then do we treat it as "now".
            let isFrontActive = isActive && winIdx == 1 && bundleIdentifier == currentFlowSourceAppBundleIdentifier
            let isCurrentFlowActiveTab = isFrontActive
            let storedTime = activeTimes[key]
            let timestamp: Date = {
                if isFrontActive { return fetchStart }
                return storedTime ?? Date(timeIntervalSince1970: 0)
            }()
            logger.info("recency-sort tab. browser='\(appName, privacy: .public)' win=\(winIdx) tab=\(tabIdx) isActive=\(isActive, privacy: .public) isFrontActive=\(isFrontActive, privacy: .public) hadStoredTime=\(storedTime != nil, privacy: .public) storedEpoch=\(storedTime?.timeIntervalSince1970 ?? -1) chosenEpoch=\(timestamp.timeIntervalSince1970) key='\(key, privacy: .public)' title='\(title, privacy: .public)'")

            if isFrontActive {
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
                    tabIndex: tabIdx,
                    windowName: windowName,
                    isCurrentFlowActiveTab: isCurrentFlowActiveTab,
                    hasMediaIndicator: hasMediaIndicator
                )
            )
        }

        return newResults
    }

    // MARK: - Lightweight active-tab poll

    func pollActiveTabKeys() -> [String] {
        // Only stamp the active tab of the FRONT window (window 1). Stamping
        // every window's active tab on every tick falsely promotes background
        // windows' active tabs to "now" whenever this browser is frontmost.
        let script = """
        tell application "\(appName)"
            if it is not running then return ""
            if (count of windows) is 0 then return ""
            set fieldSep to (ASCII character 31)
            try
                set activeTabIndex to active tab index of window 1
                set activeURL to URL of tab activeTabIndex of window 1
                return "1" & fieldSep & activeTabIndex & fieldSep & activeURL
            on error
                return ""
            end try
        end tell
        """

        guard let output = runProcess(launchPath: "/usr/bin/osascript", arguments: ["-e", script]), !output.isEmpty else {
            return []
        }

        let parts = output.components(separatedBy: kFieldSep)
        guard parts.count >= 3 else { return [] }
        let winIdx = Int(parts[0]) ?? 1
        let tabIdx = Int(parts[1]) ?? 1
        let url = parts[2]
        guard !url.isEmpty else { return [] }
        return [makeTabRecencyKey(browserName: appName, windowIndex: winIdx, tabIndex: tabIdx, url: url)]
    }

    // MARK: - Bookmarks

    func fetchAllBookmarks() -> [BrowserSearchResult] {
        let profiles = profiles()
        var results: [BrowserSearchResult] = []

        for profile in profiles {
            guard let data = try? Data(contentsOf: profile.bookmarksURL),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let roots = root["roots"] as? [String: Any] else {
                continue
            }

            for value in roots.values {
                guard let node = value as? [String: Any] else { continue }
                Self.collectBookmarks(
                    from: node,
                    browserName: appName,
                    profileName: profile.name,
                    folderTrail: [],
                    results: &results
                )
            }
        }

        return results
    }

    private static func collectBookmarks(
        from node: [String: Any],
        browserName: String,
        profileName: String,
        folderTrail: [String],
        results: inout [BrowserSearchResult]
    ) {
        let type = node["type"] as? String
        let nodeName = (node["name"] as? String) ?? ""

        if type == "url" {
            let url = (node["url"] as? String) ?? ""
            guard !url.isEmpty else { return }

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
            return
        }

        let nextTrail = type == "folder" && !nodeName.isEmpty ? folderTrail + [nodeName] : folderTrail
        guard let children = node["children"] as? [[String: Any]] else { return }
        for child in children {
            collectBookmarks(
                from: child,
                browserName: browserName,
                profileName: profileName,
                folderTrail: nextTrail,
                results: &results
            )
        }
    }

    // MARK: - History

    func fetchRecentHistory(perBrowserLimit: Int) -> [BrowserSearchResult] {
        let logger = self.logger
        var dedupedByURL: [String: BrowserSearchResult] = [:]

        for profile in profiles() {
            guard FileManager.default.fileExists(atPath: profile.historyURL.path) else { continue }
            let profileStart = Date()
            let profileQueryLimit = 150
            let sql = """
            SELECT title, url, last_visit_time
            FROM urls
            WHERE url IS NOT NULL
              AND url != ''
            ORDER BY last_visit_time DESC
            LIMIT \(profileQueryLimit);
            """

            guard let output = runProcess(
                launchPath: "/usr/bin/sqlite3",
                arguments: Self.readonlySQLiteArgs(dbPath: profile.historyURL.path, sql: sql),
                timeoutSeconds: 15
            ) else {
                logger.error("history profile query failed. app='\(appName, privacy: .public)' profile='\(profile.name, privacy: .public)'")
                continue
            }

            let rows = output.split(separator: "\n", omittingEmptySubsequences: true)
            for row in rows {
                let parts = String(row).components(separatedBy: kFieldSep)
                guard parts.count >= 3 else { continue }

                let title = parts[0].isEmpty ? parts[1] : parts[0]
                let url = parts[1]
                let timestamp = Self.chromiumDate(fromSQLiteValue: parts[2]) ?? Date(timeIntervalSince1970: 0)
                let candidate = BrowserSearchResult(
                    title: title,
                    url: url,
                    browserName: appName,
                    type: .history,
                    timestamp: timestamp,
                    profileName: profile.name
                )

                let key = "\(appName)|\(url)"
                if let existing = dedupedByURL[key], existing.timestamp >= candidate.timestamp {
                    continue
                }
                dedupedByURL[key] = candidate
            }

            let elapsedMs = Int(Date().timeIntervalSince(profileStart) * 1000)
            logger.info("history profile query complete. app='\(appName, privacy: .public)' profile='\(profile.name, privacy: .public)' rows=\(rows.count) elapsedMs=\(elapsedMs)")
        }

        return dedupedByURL.values
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(perBrowserLimit)
            .map { $0 }
    }

    func searchHistory(query: String, limit: Int) -> [BrowserSearchResult] {
        searchHistory(query: query, limit: limit, since: nil, before: nil)
    }

    func searchHistory(query: String, limit: Int, since: Date?, before: Date?) -> [BrowserSearchResult] {
        let logger = self.logger
        let escaped = query.replacingOccurrences(of: "'", with: "''")
        var dedupedByURL: [String: BrowserSearchResult] = [:]

        // Chromium `last_visit_time` is microseconds since 1601-01-01 UTC.
        func chromiumMicros(from date: Date) -> Int64 {
            let unixSeconds = date.timeIntervalSince1970
            return Int64((unixSeconds + 11_644_473_600) * 1_000_000)
        }

        var timeClauses: [String] = []
        if let since {
            timeClauses.append("last_visit_time >= \(chromiumMicros(from: since))")
        }
        if let before {
            timeClauses.append("last_visit_time < \(chromiumMicros(from: before))")
        }
        let timePredicate = timeClauses.isEmpty ? "" : " AND " + timeClauses.joined(separator: " AND ")

        for profile in profiles() {
            guard FileManager.default.fileExists(atPath: profile.historyURL.path) else { continue }
            let profileStart = Date()
            let sql = """
            SELECT title, url, last_visit_time
            FROM urls
            WHERE (url LIKE '%\(escaped)%' OR title LIKE '%\(escaped)%')
              AND url IS NOT NULL AND url != ''\(timePredicate)
            ORDER BY last_visit_time DESC
            LIMIT \(limit);
            """

            guard let output = runProcess(
                launchPath: "/usr/bin/sqlite3",
                arguments: Self.readonlySQLiteArgs(dbPath: profile.historyURL.path, sql: sql),
                timeoutSeconds: 15
            ) else {
                logger.error("searchHistory query failed. app='\(appName, privacy: .public)' profile='\(profile.name, privacy: .public)'")
                continue
            }

            let rows = output.split(separator: "\n", omittingEmptySubsequences: true)
            for row in rows {
                let parts = String(row).components(separatedBy: kFieldSep)
                guard parts.count >= 3 else { continue }

                let title = parts[0].isEmpty ? parts[1] : parts[0]
                let url = parts[1]
                let timestamp = Self.chromiumDate(fromSQLiteValue: parts[2]) ?? Date(timeIntervalSince1970: 0)
                let candidate = BrowserSearchResult(
                    title: title,
                    url: url,
                    browserName: appName,
                    type: .history,
                    timestamp: timestamp,
                    profileName: profile.name
                )

                let key = "\(appName)|\(url)"
                if let existing = dedupedByURL[key], existing.timestamp >= candidate.timestamp { continue }
                dedupedByURL[key] = candidate
            }

            let elapsedMs = Int(Date().timeIntervalSince(profileStart) * 1000)
            logger.info("searchHistory complete. app='\(appName, privacy: .public)' profile='\(profile.name, privacy: .public)' rows=\(rows.count) elapsedMs=\(elapsedMs)")
        }

        return dedupedByURL.values
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Read-only live-DB access

    /// Reads `History` directly from the live profile via SQLite's `immutable=1`
    /// URI flag. Chromium opens History with `PRAGMA locking_mode=EXCLUSIVE`, so
    /// a plain `-readonly` open is rejected with `SQLITE_BUSY (database is
    /// locked)` even though the file is on disk. `immutable=1` tells SQLite to
    /// assume the file won't change and skip all locking, which lets us read
    /// the latest checkpointed state while the browser keeps writing. We never
    /// open for write, so there's no risk of corrupting the browser's DB.
    ///
    /// We previously tried (a) byte-level `copyItem` + query — captured stale
    /// pages because the `-journal` sidecar wasn't copied alongside, and
    /// (b) `-readonly` direct open — failed with `SQLITE_BUSY` against
    /// Chromium's exclusive lock. `immutable=1` is the approach Chrome's own
    /// history-export tooling uses.
    private static func readonlySQLiteArgs(dbPath: String, sql: String) -> [String] {
        let uri = immutableSQLiteURI(dbPath: dbPath)
        return [
            "-cmd", ".timeout 3000",
            "-separator", kFieldSep,
            uri,
            sql
        ]
    }

    /// Builds a `file:` URI with `immutable=1` for the given absolute DB path.
    /// Path components must be percent-encoded so SQLite parses the URI cleanly.
    private static func immutableSQLiteURI(dbPath: String) -> String {
        "file:\(sqliteFileURIPath(dbPath))?immutable=1"
    }

    // MARK: - Favicons

    func fetchFaviconData(pageURL: String) -> Data? {
        let escapedURL = pageURL.replacingOccurrences(of: "'", with: "''")
        let originURL: String = {
            guard let parsed = URL(string: pageURL),
                  let scheme = parsed.scheme,
                  let host = parsed.host else {
                return pageURL
            }
            return "\(scheme)://\(host)/"
        }()
        let escapedOriginURL = originURL.replacingOccurrences(of: "'", with: "''")

        for profile in profiles() {
            guard FileManager.default.fileExists(atPath: profile.faviconsURL.path) else { continue }

            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-Favicons")

            do {
                try FileManager.default.copyItem(at: profile.faviconsURL, to: tempURL)

                let sql = """
                SELECT hex(fb.image_data)
                FROM icon_mapping im
                JOIN favicon_bitmaps fb ON fb.icon_id = im.icon_id
                WHERE im.page_url IN ('\(escapedURL)', '\(escapedOriginURL)')
                  AND fb.image_data IS NOT NULL
                ORDER BY fb.width DESC, fb.last_updated DESC
                LIMIT 1;
                """

                guard let output = runProcess(
                    launchPath: "/usr/bin/sqlite3",
                    arguments: [tempURL.path, sql],
                    timeoutSeconds: 6
                ), !output.isEmpty else {
                    try? FileManager.default.removeItem(at: tempURL)
                    continue
                }

                try? FileManager.default.removeItem(at: tempURL)

                if let data = dataFromHex(output) {
                    return data
                }
            } catch {
                try? FileManager.default.removeItem(at: tempURL)
            }
        }

        return nil
    }

    func fetchFaviconsBatch(pageURLs: [String]) -> [String: Data] {
        guard !pageURLs.isEmpty else { return [:] }

        // For each requested page, the icon may be keyed by either the exact URL
        // or the origin URL — track both, mapping each candidate to the originals.
        var candidateToOriginals: [String: [String]] = [:]
        for page in pageURLs {
            candidateToOriginals[page, default: []].append(page)
            if let parsed = URL(string: page), let scheme = parsed.scheme, let host = parsed.host {
                let origin = "\(scheme)://\(host)/"
                if origin != page {
                    candidateToOriginals[origin, default: []].append(page)
                }
            }
        }

        var result: [String: Data] = [:]
        var pending = Set(pageURLs)

        for profile in profiles() {
            if pending.isEmpty { break }
            guard FileManager.default.fileExists(atPath: profile.faviconsURL.path) else { continue }

            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-Favicons")
            do {
                try FileManager.default.copyItem(at: profile.faviconsURL, to: tempURL)
                defer { try? FileManager.default.removeItem(at: tempURL) }

                let inList = candidateToOriginals.keys
                    .map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }
                    .joined(separator: ",")

                let sql = """
                SELECT im.page_url, hex(fb.image_data)
                FROM icon_mapping im
                JOIN favicon_bitmaps fb ON fb.icon_id = im.icon_id
                WHERE im.page_url IN (\(inList))
                  AND fb.image_data IS NOT NULL
                ORDER BY fb.width DESC, fb.last_updated DESC;
                """

                guard let output = runProcess(
                    launchPath: "/usr/bin/sqlite3",
                    arguments: ["-separator", kFieldSep, tempURL.path, sql],
                    timeoutSeconds: 8
                ), !output.isEmpty else { continue }

                for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
                    let parts = line.split(separator: Character(kFieldSep), maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                    guard parts.count == 2 else { continue }
                    let matchedURL = parts[0]
                    let hex = parts[1]
                    guard let originals = candidateToOriginals[matchedURL] else { continue }
                    guard let data = dataFromHex(hex), !data.isEmpty else { continue }
                    for orig in originals where result[orig] == nil {
                        result[orig] = data
                        pending.remove(orig)
                    }
                }
            } catch {
                try? FileManager.default.removeItem(at: tempURL)
            }
        }

        return result
    }

    // MARK: - Actions

    func activateTab(_ result: BrowserSearchResult) {
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

    func closeTab(_ result: BrowserSearchResult) {
        let safeURL = appleScriptQuoted(result.url)
        let fallbackWindow = max(1, result.windowIndex ?? 1)
        let fallbackTab = max(1, result.tabIndex ?? 1)

        let script = """
        tell application "\(result.browserName)"
            if it is not running then return
            set targetURL to "\(safeURL)"
            set didClose to false
            try
                repeat with w in windows
                    set tabURLs to URL of every tab of w
                    repeat with i from 1 to count of tabURLs
                        if (item i of tabURLs) is equal to targetURL then
                            close tab i of w
                            set didClose to true
                            exit repeat
                        end if
                    end repeat
                    if didClose then exit repeat
                end repeat
            end try
            if didClose is false then
                try
                    close tab \(fallbackTab) of window \(fallbackWindow)
                end try
            end if
        end tell
        """

        logger.info("closeTab: app=\(result.browserName, privacy: .public) title='\(result.title, privacy: .public)' url='\(result.url, privacy: .public)'")
        runAppleScript(script, logger: logger, action: "closeTab")
    }

    func openURL(_ result: BrowserSearchResult) {
        // Profile-aware open via executable launch.
        if let profileName = result.profileName,
           let executableURL = browserExecutableURL() {
            let executablePath = executableURL.path
            let shellScript = "nohup \(shellQuoted(executablePath)) --profile-directory=\(shellQuoted(profileName)) \(shellQuoted(result.url)) > /dev/null 2>&1 &"
            let task = Process()
            task.launchPath = "/bin/bash"
            task.arguments = ["-c", shellScript]
            do {
                try task.run()
                task.waitUntilExit()
                if task.terminationStatus == 0 {
                    logger.info("openURL: app=\(result.browserName, privacy: .public) type=\(result.type.rawValue, privacy: .public) profile=\(profileName, privacy: .public) url='\(result.url, privacy: .public)'")
                    return
                }
            } catch {
                logger.error("openURL profile-aware failed: \(String(describing: error), privacy: .public)")
            }
        }

        // Fallback to AppleScript
        let safeURL = appleScriptQuoted(result.url)
        let script = """
        tell application "\(result.browserName)"
            activate
            open location "\(safeURL)"
        end tell
        """

        logger.info("openURL: app=\(result.browserName, privacy: .public) type=\(result.type.rawValue, privacy: .public) url='\(result.url, privacy: .public)' (fallback)")
        runAppleScript(script, logger: logger, action: "openURL")
    }

    func deleteBookmark(_ result: BrowserSearchResult) {
        guard let bookmarkID = result.bookmarkID else {
            logger.error("deleteBookmark: missing bookmarkID for url='\(result.url, privacy: .public)'")
            return
        }

        guard let profile = profile(for: result) else {
            logger.error("deleteBookmark: profile not found for browser=\(result.browserName, privacy: .public) profile=\(result.profileName ?? "", privacy: .public)")
            return
        }

        do {
            let data = try Data(contentsOf: profile.bookmarksURL)
            guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  var roots = root["roots"] as? [String: Any] else {
                logger.error("deleteBookmark: invalid bookmark JSON at path=\(profile.bookmarksURL.path, privacy: .public)")
                return
            }

            var deleted = false
            for (key, value) in roots {
                guard var node = value as? [String: Any] else { continue }
                if Self.deleteBookmarkNode(withID: bookmarkID, from: &node) {
                    deleted = true
                }
                roots[key] = node
            }

            guard deleted else {
                logger.error("deleteBookmark: bookmark id=\(bookmarkID, privacy: .public) not found")
                return
            }

            root["roots"] = roots
            let updatedData = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try updatedData.write(to: profile.bookmarksURL, options: .atomic)
            logger.info("deleteBookmark: removed bookmark id=\(bookmarkID, privacy: .public) from profile=\(profile.name, privacy: .public)")
        } catch {
            logger.error("deleteBookmark: failed for profile=\(profile.name, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
    }

    func deleteHistoryItem(_ result: BrowserSearchResult) {
        guard let profile = profile(for: result) else {
            logger.error("deleteHistoryItem: profile not found for browser=\(result.browserName, privacy: .public) profile=\(result.profileName ?? "", privacy: .public)")
            return
        }

        let historyURL = profile.historyURL
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-History")

        do {
            guard FileManager.default.fileExists(atPath: historyURL.path) else {
                logger.error("deleteHistoryItem: history DB missing at path=\(historyURL.path, privacy: .public)")
                return
            }

            try FileManager.default.copyItem(at: historyURL, to: tempURL)

            let escapedURL = result.url.replacingOccurrences(of: "'", with: "''")
            let sql = """
            DELETE FROM visits WHERE url IN (SELECT id FROM urls WHERE url = '\(escapedURL)');
            DELETE FROM urls WHERE url = '\(escapedURL)';
            """

            guard runProcess(launchPath: "/usr/bin/sqlite3", arguments: [tempURL.path, sql]) != nil else {
                logger.error("deleteHistoryItem: sqlite delete failed for url='\(result.url, privacy: .public)'")
                try? FileManager.default.removeItem(at: tempURL)
                return
            }

            _ = try FileManager.default.replaceItemAt(historyURL, withItemAt: tempURL)
            logger.info("deleteHistoryItem: removed url='\(result.url, privacy: .public)' from profile=\(profile.name, privacy: .public)")
        } catch {
            logger.error("deleteHistoryItem: failed for profile=\(profile.name, privacy: .public) error=\(String(describing: error), privacy: .public)")
            try? FileManager.default.removeItem(at: tempURL)
        }
    }

    private static func deleteBookmarkNode(withID bookmarkID: String, from node: inout [String: Any]) -> Bool {
        guard let children = node["children"] as? [[String: Any]] else {
            return false
        }

        var deletedAny = false
        var nextChildren: [[String: Any]] = []
        nextChildren.reserveCapacity(children.count)

        for var child in children {
            if (child["id"] as? String) == bookmarkID {
                deletedAny = true
                continue
            }

            if deleteBookmarkNode(withID: bookmarkID, from: &child) {
                deletedAny = true
            }

            nextChildren.append(child)
        }

        if deletedAny {
            node["children"] = nextChildren
        }

        return deletedAny
    }

    // MARK: - Profile helpers

    func profiles() -> [ChromiumProfile] {
        let basePath = (supportDirectory as NSString).expandingTildeInPath
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
                return ChromiumProfile(browserAppName: appName, name: url.lastPathComponent, directoryURL: url)
            }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    private func profile(for result: BrowserSearchResult) -> ChromiumProfile? {
        let all = profiles()
        if let profileName = result.profileName {
            return all.first(where: { $0.name == profileName })
        }
        return all.first
    }

    private func browserExecutableURL() -> URL? {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return nil
        }
        let infoPlistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let infoPlist = NSDictionary(contentsOf: infoPlistURL),
              let executableName = infoPlist["CFBundleExecutable"] as? String else {
            return nil
        }
        return appURL.appendingPathComponent("Contents/MacOS/\(executableName)")
    }

    // MARK: - Date helpers

    private static func chromiumDate(from rawValue: String?) -> Date? {
        guard let rawValue, let microseconds = Double(rawValue) else { return nil }
        return Date(timeIntervalSince1970: (microseconds / 1_000_000) - 11_644_473_600)
    }

    private static func chromiumDate(fromSQLiteValue rawValue: String) -> Date? {
        guard let microseconds = Double(rawValue) else { return nil }
        return Date(timeIntervalSince1970: (microseconds / 1_000_000) - 11_644_473_600)
    }
}
