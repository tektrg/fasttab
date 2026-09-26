import Foundation
import AppKit
import OSLog
import CommandBarKit

struct ChromiumProfile: Sendable {
    let browserAppName: String
    let name: String
    let directoryURL: URL

    var bookmarksURL: URL { directoryURL.appendingPathComponent("Bookmarks") }
    var historyURL: URL { directoryURL.appendingPathComponent("History") }
    var faviconsURL: URL { directoryURL.appendingPathComponent("Favicons") }
    /// Holds the `keywords` table — the browser's own address-bar search
    /// engines, which FastTab imports as search aliases.
    var webDataURL: URL { directoryURL.appendingPathComponent("Web Data") }
}

struct ChromiumBackend: BrowserBackend {
    let appName: String
    let bundleIdentifier: String
    let supportDirectory: String

    private static let bookmarkFileLock = NSLock()

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
            let urlKey = makeTabURLRecencyKey(browserName: appName, url: url)
            // The active tab of the FRONT window (winIdx == 1) of the
            // source browser is treated as "the tab the user is on" and
            // stamped as "now" (fetchStart). Other windows' active tabs are
            // stamped just behind it.
            // The tab is "currently being viewed" only when it is the active
            // tab of the front window AND its app is the frontmost app the
            // user activated FastTab from.
            let isFrontActive = isActive && winIdx == 1 && bundleIdentifier == currentFlowSourceAppBundleIdentifier
            let isCurrentFlowActiveTab = isFrontActive
            let storedTime = activeTimes[key] ?? activeTimes[urlKey]
            let timestamp: Date = {
                if isFrontActive { return fetchStart }
                if isActive { return fetchStart.addingTimeInterval(-1) }
                return storedTime ?? Date(timeIntervalSince1970: 0)
            }()
            logger.info("recency-sort tab. browser='\(appName, privacy: .public)' win=\(winIdx) tab=\(tabIdx) isActive=\(isActive, privacy: .public) isFrontActive=\(isFrontActive, privacy: .public) hadStoredTime=\(storedTime != nil, privacy: .public) storedEpoch=\(storedTime?.timeIntervalSince1970 ?? -1) chosenEpoch=\(timestamp.timeIntervalSince1970) key='\(key, privacy: .public)' title='\(title, privacy: .public)'")

            if isFrontActive {
                activeTimes[key] = fetchStart
                activeTimes[urlKey] = fetchStart
            } else if isActive {
                let windowActiveTime = fetchStart.addingTimeInterval(-1)
                activeTimes[key] = windowActiveTime
                activeTimes[urlKey] = windowActiveTime
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
                    profileName: Frecency.profileFromWindowTitle(windowName),
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
        return [
            makeTabRecencyKey(browserName: appName, windowIndex: winIdx, tabIndex: tabIdx, url: url),
            makeTabURLRecencyKey(browserName: appName, url: url)
        ]
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

    func fetchBookmarkTree() -> [BookmarkFolder] {
        let profiles = profiles()
        var folders: [BookmarkFolder] = []
        let standardOrder = ["bookmark_bar", "other", "synced"]

        for profile in profiles {
            guard let data = try? Data(contentsOf: profile.bookmarksURL),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let roots = root["roots"] as? [String: Any] else {
                continue
            }

            let extraKeys = roots.keys.filter { !standardOrder.contains($0) }.sorted()
            let orderedKeys = standardOrder.filter { roots.keys.contains($0) } + extraKeys

            var profileFolders: [BookmarkFolder] = []
            for rootKey in orderedKeys {
                guard let node = roots[rootKey] as? [String: Any] else { continue }
                if let folder = Self.parseBookmarkFolder(
                    from: node,
                    defaultName: rootKey.replacingOccurrences(of: "_", with: " ").capitalized,
                    browserName: appName,
                    profileName: profile.name,
                    parentTrail: []
                ) {
                    if folder.childCount > 0 || rootKey == "bookmark_bar" {
                        profileFolders.append(folder)
                    }
                }
            }

            let totalBookmarks = profileFolders.reduce(0) { $0 + $1.childCount }
            if totalBookmarks > 0 {
                folders.append(contentsOf: profileFolders)
            }
        }

        return folders
    }

    private static func parseBookmarkFolder(
        from node: [String: Any],
        defaultName: String,
        browserName: String,
        profileName: String,
        parentTrail: [String]
    ) -> BookmarkFolder? {
        let nodeName = (node["name"] as? String) ?? defaultName
        let rawID = (node["id"] as? String) ?? UUID().uuidString
        let id = "\(browserName)|\(profileName)|\(rawID)"
        let currentTrail = parentTrail + [nodeName]

        guard let childrenNodes = node["children"] as? [[String: Any]] else {
            return nil
        }

        var children: [BookmarkTreeNode] = []
        for child in childrenNodes {
            let childType = child["type"] as? String
            let childName = (child["name"] as? String) ?? ""
            let childID = (child["id"] as? String) ?? UUID().uuidString

            if childType == "url" {
                let url = (child["url"] as? String) ?? ""
                guard !url.isEmpty else { continue }
                let item = BookmarkItem(
                    id: childID,
                    title: childName.isEmpty ? url : childName,
                    url: url,
                    browserName: browserName,
                    profileName: profileName,
                    dateAdded: chromiumDate(from: child["date_added"] as? String),
                    folderPath: currentTrail.joined(separator: " / ")
                )
                children.append(.item(item))
            } else if childType == "folder" {
                if let subFolder = parseBookmarkFolder(
                    from: child,
                    defaultName: childName,
                    browserName: browserName,
                    profileName: profileName,
                    parentTrail: currentTrail
                ) {
                    children.append(.folder(subFolder))
                }
            }
        }

        return BookmarkFolder(
            id: id,
            name: nodeName,
            browserName: browserName,
            profileName: profileName,
            children: children
        )
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

        // If this is an empty folder with a valid trail, emit a placeholder item
        // so CloudKit sync and iOS tree views know this folder exists.
        if type == "folder", children.isEmpty, !nextTrail.isEmpty {
            results.append(
                BrowserSearchResult(
                    title: nodeName,
                    url: "",
                    browserName: browserName,
                    type: .bookmark,
                    timestamp: chromiumDate(from: node["date_added"] as? String) ?? Date(timeIntervalSince1970: 0),
                    bookmarkID: node["id"] as? String,
                    profileName: profileName,
                    folderPath: nextTrail.joined(separator: " / ")
                )
            )
        }

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
            let profileQueryLimit = 500
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
                arguments: immutableReadSQLiteArgs(dbPath: profile.historyURL.path, sql: sql),
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
        searchHistory(query: query, limit: limit, since: since, before: before, timeoutSeconds: 15)
    }

    func searchHistory(
        query: String,
        limit: Int,
        since: Date?,
        before: Date?,
        timeoutSeconds: TimeInterval
    ) -> [BrowserSearchResult] {
        let logger = self.logger
        // Word-by-word, accent-insensitive. A single `LIKE '%<whole query>%'`
        // required the typed phrase to appear verbatim, so "real time bi hub"
        // never matched the title "Realtime e-commerce order | Bi Hub".
        let textPredicate = historySearchSQLPredicate(query: query, urlColumn: "url", titleColumn: "title")
        var dedupedByURL: [String: BrowserSearchResult] = [:]
        let deadline = Date().addingTimeInterval(timeoutSeconds)

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
            // A superseded search (the user kept typing) has already stopped
            // caring about this result — stop launching another `sqlite3`
            // subprocess per remaining profile once cancelled.
            if Task.isCancelled { break }
            let remainingSeconds = deadline.timeIntervalSinceNow
            guard remainingSeconds > 0 else { break }
            guard FileManager.default.fileExists(atPath: profile.historyURL.path) else { continue }
            let profileStart = Date()
            let sql = """
            SELECT title, url, last_visit_time
            FROM urls
            WHERE \(textPredicate)
              AND url IS NOT NULL AND url != ''\(timePredicate)
            ORDER BY last_visit_time DESC
            LIMIT \(limit);
            """

            guard let output = runProcess(
                launchPath: "/usr/bin/sqlite3",
                arguments: immutableReadSQLiteArgs(dbPath: profile.historyURL.path, sql: sql),
                timeoutSeconds: max(0.05, remainingSeconds)
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

    static func buildCloseTabScript(
        appName: String,
        url: String,
        fallbackWindow: Int,
        fallbackTab: Int,
        allowPositionalFallback: Bool
    ) -> String {
        let safeURL = appleScriptQuoted(url)
        return """
        tell application "\(appName)"
            if it is not running then return "not_found"
            set targetURL to "\(safeURL)"
            try
                set winCount to count of windows
                if winCount >= \(fallbackWindow) then
                    set w to window \(fallbackWindow)
                    set tabURLs to URL of every tab of w
                    if (count of tabURLs) >= \(fallbackTab) then
                        if (item \(fallbackTab) of tabURLs) is equal to targetURL then
                            close tab \(fallbackTab) of w
                            return "closed"
                        end if
                    end if
                end if
            end try
            set matchCount to 0
            set targetWin to 0
            set targetTab to 0
            try
                repeat with wIdx from 1 to count of windows
                    set w to window wIdx
                    set tabURLs to URL of every tab of w
                    repeat with i from 1 to count of tabURLs
                        if (item i of tabURLs) is equal to targetURL then
                            set matchCount to matchCount + 1
                            set targetWin to wIdx
                            set targetTab to i
                        end if
                    end repeat
                end repeat
            end try
            if matchCount is equal to 0 then
                return "not_found"
            \(allowPositionalFallback ? """
            else
                try
                    close tab targetTab of window targetWin
                    return "closed"
                end try
                return "not_found"
            """ : """
            else if matchCount is greater than 1 then
                return "refused:ambiguous"
            else
                try
                    close tab targetTab of window targetWin
                    return "closed"
                end try
                return "not_found"
            """)
            end if
        end tell
        """
    }

    func closeTab(_ result: BrowserSearchResult) {
        _ = closeTabWithResult(result, allowPositionalFallback: true)
    }

    func closeTabWithResult(_ result: BrowserSearchResult, allowPositionalFallback: Bool) -> TabCloseResult {
        let fallbackWindow = max(1, result.windowIndex ?? 1)
        let fallbackTab = max(1, result.tabIndex ?? 1)
        let script = Self.buildCloseTabScript(
            appName: result.browserName,
            url: result.url,
            fallbackWindow: fallbackWindow,
            fallbackTab: fallbackTab,
            allowPositionalFallback: allowPositionalFallback
        )

        logger.info("closeTabWithResult: app=\(result.browserName, privacy: .public) allowPositional=\(allowPositionalFallback) title='\(result.title, privacy: .public)' url='\(result.url, privacy: .public)'")
        let output = runProcess(launchPath: "/usr/bin/osascript", arguments: ["-e", script], timeoutSeconds: 8)
        switch output {
        case "closed":
            return .closed
        case "refused:ambiguous":
            return .refused("Ambiguous tab URL: multiple tabs open with identical URL")
        case "not_found":
            return .notFound
        default:
            return .notFound
        }
    }

    static func buildOpenURLScript(appName: String, url: String, windowIndex: Int?) -> String {
        let safeURL = appleScriptQuoted(url)
        // Ghost slots remember the window they lived in, which pins the
        // profile (each window belongs to one profile) even when profileName
        // is unknown. Fronting that window first makes `open location` land
        // in the correct profile instead of whatever window is frontmost.
        // The `try` keeps a stale index (window since closed) a safe no-op
        // that falls back to front-window behavior.
        if let win = windowIndex, win >= 1 {
            return """
            tell application "\(appName)"
                activate
                try
                    set index of window \(win) to 1
                end try
                open location "\(safeURL)"
            end tell
            """
        }
        return """
        tell application "\(appName)"
            activate
            open location "\(safeURL)"
        end tell
        """
    }

    func openURL(_ result: BrowserSearchResult) {
        // Profile-aware open via executable launch. profileName may be a
        // directory ("Profile 1") or a display name parsed from the window
        // title ("Work") — resolve display names via Local State first.
        if let profileName = result.profileName,
           !profileName.isEmpty,
           let directory = Self.resolveProfileDirectory(
               supportDirectory: supportDirectory,
               profileName: profileName
           ),
           let executableURL = browserExecutableURL() {
            let shellScript = "nohup \(shellQuoted(executableURL.path)) --profile-directory=\(shellQuoted(directory)) \(shellQuoted(result.url)) > /dev/null 2>&1 &"
            if runDetachedShellCommand(shellScript) {
                logger.info("openURL: app=\(result.browserName, privacy: .public) type=\(result.type.rawValue, privacy: .public) profile=\(profileName, privacy: .public) url='\(result.url, privacy: .public)'")
                return
            }
        }

        // Fallback to AppleScript — window-targeted when known so ghost
        // reopens land in their original window/profile.
        let script = Self.buildOpenURLScript(appName: result.browserName, url: result.url, windowIndex: result.windowIndex)

        logger.info("openURL: app=\(result.browserName, privacy: .public) type=\(result.type.rawValue, privacy: .public) url='\(result.url, privacy: .public)' (fallback)")
        runAppleScript(script, logger: logger, action: "openURL")
    }

    /// Opens `result` inside `app`'s installed chromeless window.
    ///
    /// Two-step by necessity: launching the app bundle with a URL argument
    /// silently ignores it (lands on the app's home page), and launching the
    /// browser with an `--app=<url>` flag hits the target page but produces a
    /// throwaway window our fingerprint below can't recognise later — every
    /// click would spawn another window. So: find or launch the real app
    /// window first, then steer it.
    func openInInstalledWebApp(_ result: BrowserSearchResult, app: InstalledWebApp) {
        if let existingIndex = findExistingAppWindowIndex(for: app) {
            logger.info("openInInstalledWebApp: reusing window. app='\(app.name, privacy: .public)' index=\(existingIndex)")
            steerAppWindow(index: existingIndex, to: result.url, app: app)
            return
        }

        guard launchInstalledAppBundle(app) else {
            logger.error("openInInstalledWebApp: launch failed, falling back to normal tab. app='\(app.name, privacy: .public)'")
            openURL(result)
            return
        }

        let deadline = Date().addingTimeInterval(4)
        var newIndex: Int?
        while newIndex == nil && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
            newIndex = findExistingAppWindowIndex(for: app)
        }

        guard let newIndex else {
            logger.error("openInInstalledWebApp: app window never appeared after launch, falling back to normal tab. app='\(app.name, privacy: .public)'")
            openURL(result)
            return
        }

        let alreadyOnTargetPage = result.url.trimmingCharacters(in: .whitespacesAndNewlines)
            == app.homeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if alreadyOnTargetPage {
            activateRunningApp(bundleIdentifier: app.appBundleIdentifier)
        } else {
            steerAppWindow(index: newIndex, to: result.url, app: app)
        }
    }

    /// Real installed-app windows are the only windows this browser ever
    /// reports as not closeable, not resizable, not zoomable, not
    /// minimizable, with a blank title and exactly one tab — verified live
    /// against multiple installed apps; every normal window reports the
    /// opposite on all four booleans.
    private func fingerprintedAppWindows() -> [(index: Int, url: String)] {
        let script = """
        tell application "\(appName)"
            if it is not running then return ""
            set fieldSep to (ASCII character 31)
            set rowSep to (ASCII character 28)
            set outData to ""
            try
                repeat with w from 1 to (count of windows)
                    try
                        set isAppWindow to (not (closeable of window w)) and (not (resizable of window w)) and (not (zoomable of window w)) and (not (minimizable of window w)) and ((name of window w) is "") and ((count of tabs of window w) is 1)
                        if isAppWindow then
                            set rowData to (w as string) & fieldSep & (URL of tab 1 of window w)
                            if outData is "" then
                                set outData to rowData
                            else
                                set outData to outData & rowSep & rowData
                            end if
                        end if
                    end try
                end repeat
            end try
            return outData
        end tell
        """

        guard let output = runProcess(launchPath: "/usr/bin/osascript", arguments: ["-e", script]), !output.isEmpty else {
            return []
        }

        return output.components(separatedBy: kRowSep).compactMap { row in
            let parts = row.components(separatedBy: kFieldSep)
            guard parts.count >= 2, let index = Int(parts[0]) else { return nil }
            return (index, parts[1])
        }
    }

    /// Finds a currently open window belonging to `app` by comparing site
    /// identity (scheme+host+port), not exact URL — the window may already
    /// have been steered to a different page of the same site. When two
    /// installed apps share a route key (e.g. Docs and Sheets both on
    /// `docs.google.com`) and both have a window open, `selectWindow`
    /// disambiguates by path segment so this never steers the wrong app's
    /// window; if that's still ambiguous, returns nil rather than guessing.
    private func findExistingAppWindowIndex(for app: InstalledWebApp) -> Int? {
        selectWindow(for: app, among: fingerprintedAppWindows(), urlOf: \.url)?.index
    }

    /// Installed web apps run as their own Dock/Cmd-Tab entity even though
    /// AppleScript reaches their window through the parent browser's `tell
    /// application "\(appName)"` (see `fingerprintedAppWindows()`). Telling
    /// the browser to `activate` only raises whichever of *its own* windows
    /// last had focus — usually the regular browser window, not this app's.
    /// Activating the app's own running process first is what actually
    /// switches the user to it.
    private func steerAppWindow(index: Int, to url: String, app: InstalledWebApp) {
        activateRunningApp(bundleIdentifier: app.appBundleIdentifier)

        let safeURL = appleScriptQuoted(url)
        let script = """
        tell application "\(appName)"
            try
                set URL of tab 1 of window \(index) to "\(safeURL)"
                set index of window \(index) to 1
            end try
        end tell
        """
        runAppleScript(script, logger: logger, action: "steerAppWindow")
    }

    private func activateRunningApp(bundleIdentifier: String) {
        guard let runningApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            return
        }
        runningApp.activate()
    }

    private func launchInstalledAppBundle(_ app: InstalledWebApp) -> Bool {
        runDetachedShellCommand("nohup /usr/bin/open -b \(shellQuoted(app.appBundleIdentifier)) > /dev/null 2>&1 &")
    }

    /// Shared by `openURL`'s profile-aware launch and
    /// `launchInstalledAppBundle` — both fire a detached shell command and
    /// only care whether the launch itself succeeded.
    private func runDetachedShellCommand(_ command: String) -> Bool {
        let task = Process()
        task.launchPath = "/bin/bash"
        task.arguments = ["-c", command]
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            logger.error("runDetachedShellCommand failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    @discardableResult
    func deleteBookmark(_ result: BrowserSearchResult) -> Bool {
        guard let bookmarkID = result.bookmarkID else {
            logger.error("deleteBookmark: missing bookmarkID for url='\(result.url, privacy: .public)'")
            return false
        }

        guard let profile = profile(for: result) else {
            logger.error("deleteBookmark: profile not found for browser=\(result.browserName, privacy: .public) profile=\(result.profileName ?? "", privacy: .public)")
            return false
        }

        Self.bookmarkFileLock.lock()
        defer { Self.bookmarkFileLock.unlock() }

        do {
            let data = try Data(contentsOf: profile.bookmarksURL)
            guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  var roots = root["roots"] as? [String: Any] else {
                logger.error("deleteBookmark: invalid bookmark JSON at path=\(profile.bookmarksURL.path, privacy: .public)")
                return false
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
                return false
            }

            root["roots"] = roots
            let updatedData = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try updatedData.write(to: profile.bookmarksURL, options: .atomic)
            logger.info("deleteBookmark: removed bookmark id=\(bookmarkID, privacy: .public) from profile=\(profile.name, privacy: .public)")
            return true
        } catch {
            logger.error("deleteBookmark: failed for profile=\(profile.name, privacy: .public) error=\(String(describing: error), privacy: .public)")
            return false
        }
    }

    // MARK: - Move support

    /// Removes a bookmark the same way `deleteBookmark` does, but also walks
    /// the folder trail on the way down (mirrors `collectBookmarks`) so the
    /// caller can recreate the node elsewhere, or restore it to exactly where
    /// it came from if the destination write fails.
    func removeBookmarkForMove(_ result: BrowserSearchResult) -> RemovedBookmarkNode? {
        guard let bookmarkID = result.bookmarkID else {
            logger.error("removeBookmarkForMove: missing bookmarkID for url='\(result.url, privacy: .public)'")
            return nil
        }

        guard let profile = profile(for: result) else {
            logger.error("removeBookmarkForMove: profile not found for browser=\(result.browserName, privacy: .public) profile=\(result.profileName ?? "", privacy: .public)")
            return nil
        }

        do {
            let data = try Data(contentsOf: profile.bookmarksURL)
            guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  var roots = root["roots"] as? [String: Any] else {
                logger.error("removeBookmarkForMove: invalid bookmark JSON at path=\(profile.bookmarksURL.path, privacy: .public)")
                return nil
            }

            var removed: RemovedBookmarkNode?
            for (key, value) in roots {
                guard var node = value as? [String: Any] else { continue }
                let rootName = (node["name"] as? String) ?? ""
                let rootTrail = rootName.isEmpty ? [] : [rootName]
                if let found = Self.extractBookmarkNode(withID: bookmarkID, from: &node, folderTrail: rootTrail) {
                    removed = found
                    roots[key] = node
                    break
                }
            }

            guard let removed else {
                logger.error("removeBookmarkForMove: bookmark id=\(bookmarkID, privacy: .public) not found")
                return nil
            }

            root["roots"] = roots
            let updatedData = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try updatedData.write(to: profile.bookmarksURL, options: .atomic)
            logger.info("removeBookmarkForMove: removed bookmark id=\(bookmarkID, privacy: .public) from profile=\(profile.name, privacy: .public)")
            return removed
        } catch {
            logger.error("removeBookmarkForMove: failed for profile=\(profile.name, privacy: .public) error=\(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Writes a brand-new bookmark node into `profileName` at `folderPath` (an
    /// ordered list of folder *display* names, matching how `folderPath` is
    /// derived in `collectBookmarks`). An empty path resolves to this
    /// browser's "other" root by JSON key — Chromium's own catch-all folder,
    /// matched by key rather than display name since the key is stable across
    /// locales and there's no path segment to match against for "top level".
    func insertBookmark(title: String, url: String, dateAdded: Date?, profileName: String, folderPath: [String]) -> Bool {
        guard let profile = profiles().first(where: { $0.name == profileName }) else {
            logger.error("insertBookmark: profile not found name=\(profileName, privacy: .public)")
            return false
        }

        do {
            let data = try Data(contentsOf: profile.bookmarksURL)
            guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  var roots = root["roots"] as? [String: Any] else {
                logger.error("insertBookmark: invalid bookmark JSON at path=\(profile.bookmarksURL.path, privacy: .public)")
                return false
            }

            var nextID = Self.highestBookmarkID(in: roots) + 1
            let newNode: [String: Any] = [
                "type": "url",
                "name": title,
                "url": url,
                "id": String(nextID),
                "date_added": Self.chromiumDateString(from: dateAdded ?? Date())
            ]
            // The URL node took `nextID`; ids after this go to any folder nodes
            // `insertIntoFolder` has to create along the destination trail.
            nextID += 1

            var inserted = false
            for (key, value) in roots {
                guard var node = value as? [String: Any] else { continue }
                let rootName = (node["name"] as? String) ?? ""
                let matchesTopLevel = folderPath.isEmpty && key == "other"
                let matchesNamedPath = !folderPath.isEmpty && rootName == folderPath[0]
                guard matchesTopLevel || matchesNamedPath else { continue }

                let remaining = folderPath.isEmpty ? [] : Array(folderPath.dropFirst())
                if Self.insertIntoFolder(&node, remainingPath: remaining, newNode: newNode, nextID: &nextID) {
                    roots[key] = node
                    inserted = true
                    break
                }
            }

            // A destination path whose first segment isn't a top-level root gets
            // created under Chromium's catch-all "other" root — the same place an
            // empty (top-level) destination lands, just nested. This is what lets
            // a whole-folder move re-create its folder at the destination even
            // when nothing there matches its name yet; a single-bookmark move
            // always targets an existing folder, so it only reaches here on a
            // stale destination.
            if !inserted, !folderPath.isEmpty {
                guard var otherNode = roots["other"] as? [String: Any] else {
                    logger.error("insertBookmark: no 'other' root to create destination folder under path='\(folderPath.joined(separator: " / "), privacy: .public)'")
                    return false
                }
                if Self.insertIntoFolder(&otherNode, remainingPath: folderPath, newNode: newNode, nextID: &nextID) {
                    roots["other"] = otherNode
                    inserted = true
                }
            }

            guard inserted else {
                logger.error("insertBookmark: destination folder not found path='\(folderPath.joined(separator: " / "), privacy: .public)'")
                return false
            }

            root["roots"] = roots
            let updatedData = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try updatedData.write(to: profile.bookmarksURL, options: .atomic)
            logger.info("insertBookmark: added '\(title, privacy: .public)' to profile=\(profile.name, privacy: .public) path='\(folderPath.joined(separator: " / "), privacy: .public)'")
            return true
        } catch {
            logger.error("insertBookmark: failed for profile=\(profile.name, privacy: .public) error=\(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Creates a brand-new folder node into `profileName` at `parentPath`.
    /// If a folder with `name` already exists at that path, it returns true (idempotent).
    func createBookmarkFolder(name: String, parentPath: [String], profileName: String) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return false }

        guard let profile = profiles().first(where: { $0.name == profileName }) else {
            logger.error("createBookmarkFolder: profile not found name=\(profileName, privacy: .public)")
            return false
        }

        do {
            let data = try Data(contentsOf: profile.bookmarksURL)
            guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  var roots = root["roots"] as? [String: Any] else {
                logger.error("createBookmarkFolder: invalid bookmark JSON at path=\(profile.bookmarksURL.path, privacy: .public)")
                return false
            }

            var nextID = Self.highestBookmarkID(in: roots) + 1
            let newFolderNode: [String: Any] = [
                "type": "folder",
                "name": trimmedName,
                "id": String(nextID),
                "date_added": Self.chromiumDateString(from: Date()),
                "children": [] as [[String: Any]]
            ]
            nextID += 1

            var created = false
            for (key, value) in roots {
                guard var node = value as? [String: Any] else { continue }
                let rootName = (node["name"] as? String) ?? ""
                let matchesTopLevel = parentPath.isEmpty && key == "other"
                let matchesNamedPath = !parentPath.isEmpty && rootName == parentPath[0]
                guard matchesTopLevel || matchesNamedPath else { continue }

                let remaining = parentPath.isEmpty ? [] : Array(parentPath.dropFirst())
                if Self.insertFolderUnderPath(&node, remainingPath: remaining, newFolderNode: newFolderNode, nextID: &nextID) {
                    roots[key] = node
                    created = true
                    break
                }
            }

            if !created, !parentPath.isEmpty {
                guard var otherNode = roots["other"] as? [String: Any] else {
                    logger.error("createBookmarkFolder: no 'other' root to create folder under path='\(parentPath.joined(separator: " / "), privacy: .public)'")
                    return false
                }
                if Self.insertFolderUnderPath(&otherNode, remainingPath: parentPath, newFolderNode: newFolderNode, nextID: &nextID) {
                    roots["other"] = otherNode
                    created = true
                }
            }

            guard created else {
                logger.error("createBookmarkFolder: destination folder not found path='\(parentPath.joined(separator: " / "), privacy: .public)'")
                return false
            }

            root["roots"] = roots
            let updatedData = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try updatedData.write(to: profile.bookmarksURL, options: .atomic)
            logger.info("createBookmarkFolder: created '\(trimmedName, privacy: .public)' in profile=\(profile.name, privacy: .public) under path='\(parentPath.joined(separator: " / "), privacy: .public)'")
            return true
        } catch {
            logger.error("createBookmarkFolder: failed for profile=\(profile.name, privacy: .public) error=\(String(describing: error), privacy: .public)")
            return false
        }
    }

    private static func insertFolderUnderPath(
        _ node: inout [String: Any],
        remainingPath: [String],
        newFolderNode: [String: Any],
        nextID: inout Int
    ) -> Bool {
        guard var children = node["children"] as? [[String: Any]] else { return false }

        if remainingPath.isEmpty {
            let targetName = (newFolderNode["name"] as? String) ?? ""
            // Idempotency: if folder already exists with this name, consider it done
            if children.contains(where: { ($0["type"] as? String) == "folder" && ($0["name"] as? String) == targetName }) {
                return true
            }
            children.append(newFolderNode)
            node["children"] = children
            return true
        }

        let next = remainingPath[0]
        let rest = Array(remainingPath.dropFirst())
        for i in children.indices {
            guard (children[i]["type"] as? String) == "folder",
                  (children[i]["name"] as? String) == next else { continue }
            var child = children[i]
            if insertFolderUnderPath(&child, remainingPath: rest, newFolderNode: newFolderNode, nextID: &nextID) {
                children[i] = child
                node["children"] = children
                return true
            }
        }

        // `next` isn't on this trail yet; create intermediate folder
        var createdFolder: [String: Any] = [
            "type": "folder",
            "name": next,
            "id": String(nextID),
            "date_added": Self.chromiumDateString(from: Date()),
            "children": [] as [[String: Any]]
        ]
        nextID += 1
        if insertFolderUnderPath(&createdFolder, remainingPath: rest, newFolderNode: newFolderNode, nextID: &nextID) {
            children.append(createdFolder)
            node["children"] = children
            return true
        }
        return false
    }

    private static func extractBookmarkNode(
        withID bookmarkID: String,
        from node: inout [String: Any],
        folderTrail: [String]
    ) -> RemovedBookmarkNode? {
        guard let children = node["children"] as? [[String: Any]] else { return nil }

        var extracted: RemovedBookmarkNode?
        var nextChildren: [[String: Any]] = []
        nextChildren.reserveCapacity(children.count)

        for var child in children {
            if extracted == nil, (child["id"] as? String) == bookmarkID {
                extracted = RemovedBookmarkNode(
                    title: (child["name"] as? String) ?? "",
                    url: (child["url"] as? String) ?? "",
                    dateAdded: chromiumDate(from: child["date_added"] as? String),
                    originalFolderPath: folderTrail
                )
                continue
            }

            if extracted == nil {
                let childName = (child["name"] as? String) ?? ""
                let childIsFolder = (child["type"] as? String) == "folder"
                let childTrail = childIsFolder && !childName.isEmpty ? folderTrail + [childName] : folderTrail
                if let found = extractBookmarkNode(withID: bookmarkID, from: &child, folderTrail: childTrail) {
                    extracted = found
                }
            }

            nextChildren.append(child)
        }

        if extracted != nil {
            node["children"] = nextChildren
        }
        return extracted
    }

    private static func insertIntoFolder(
        _ node: inout [String: Any],
        remainingPath: [String],
        newNode: [String: Any],
        nextID: inout Int
    ) -> Bool {
        guard var children = node["children"] as? [[String: Any]] else { return false }

        if remainingPath.isEmpty {
            children.append(newNode)
            node["children"] = children
            return true
        }

        let next = remainingPath[0]
        let rest = Array(remainingPath.dropFirst())
        for i in children.indices {
            guard (children[i]["type"] as? String) == "folder",
                  (children[i]["name"] as? String) == next else { continue }
            var child = children[i]
            if insertIntoFolder(&child, remainingPath: rest, newNode: newNode, nextID: &nextID) {
                children[i] = child
                node["children"] = children
                return true
            }
        }

        // `next` isn't on this trail yet. A whole-folder move lands leaves in a
        // destination path whose own folder isn't there (moving "Work" into
        // "Archive" writes into "Archive/Work"), so create the missing folder
        // and keep descending. A single-bookmark move always targets an
        // existing folder, so this branch never fires for it.
        var created: [String: Any] = [
            "type": "folder",
            "name": next,
            "id": String(nextID),
            "date_added": Self.chromiumDateString(from: Date()),
            "children": [] as [[String: Any]]
        ]
        nextID += 1
        // Descending into a folder we just created can't fail — the rest of the
        // trail is created recursively, and the fresh folder has a children array.
        if insertIntoFolder(&created, remainingPath: rest, newNode: newNode, nextID: &nextID) {
            children.append(created)
            node["children"] = children
            return true
        }
        return false
    }

    private static func highestBookmarkID(in roots: [String: Any]) -> Int {
        var maxID = 0
        func walk(_ node: [String: Any]) {
            if let idString = node["id"] as? String, let idValue = Int(idString) {
                maxID = max(maxID, idValue)
            }
            if let children = node["children"] as? [[String: Any]] {
                children.forEach(walk)
            }
        }
        for value in roots.values {
            if let node = value as? [String: Any] {
                walk(node)
            }
        }
        return maxID
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

    /// Resolves a stored profile reference to a `--profile-directory` value.
    /// Slots carry whatever the live-tab poll knew: usually a directory name
    /// ("Default", "Profile 1"), but since the window-title parse it can be
    /// the user-visible display name ("Work"). Directories pass straight
    /// through (verified against the profile folders on disk); display names
    /// resolve via the browser's Local State `profile.info_cache`. Returns
    /// nil when nothing matches — callers fall back to window-targeted open.
    static func resolveProfileDirectory(supportDirectory: String, profileName: String) -> String? {
        let trimmed = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let basePath = (supportDirectory as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: (basePath as NSString).appendingPathComponent(trimmed), isDirectory: &isDir), isDir.boolValue {
            return trimmed
        }
        if let mapped = Self.displayNameToDirectory(basePath: basePath, displayName: trimmed) {
            return mapped
        }
        return nil
    }

    private static func displayNameToDirectory(basePath: String, displayName: String) -> String? {
        let localStateURL = URL(fileURLWithPath: basePath, isDirectory: true).appendingPathComponent("Local State")
        guard let data = try? Data(contentsOf: localStateURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = root["profile"] as? [String: Any],
              let infoCache = profile["info_cache"] as? [String: Any] else {
            return nil
        }
        for (directory, info) in infoCache {
            if let infoDict = info as? [String: Any],
               let name = infoDict["name"] as? String,
               name.trimmingCharacters(in: .whitespacesAndNewlines) == displayName {
                return directory
            }
        }
        return nil
    }

    /// Profile directory names the browser currently has open, detected via
    /// its running process's open file handles (no Automation permission
    /// needed — this is process inspection, not Apple Events). `profiles()`
    /// counts every profile folder ever created, including long-abandoned
    /// ones (an unused "Guest Profile", a profile from years ago); the
    /// extension-completeness check needs to know which profiles are
    /// actually live right now, or it can never be satisfied. Returns nil
    /// when this can't be determined (browser not running, `lsof` missing) —
    /// callers should fall back to the full disk count rather than
    /// under-count and risk treating a partial extension snapshot as complete.
    func livingProfileNames() -> Set<String>? {
        let knownNames = Set(profiles().map(\.name))
        guard !knownNames.isEmpty else { return nil }

        let pids = NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == bundleIdentifier }
            .map(\.processIdentifier)
        guard !pids.isEmpty else { return nil }

        var living = Set<String>()
        for pid in pids {
            guard let output = Self.runLSOF(pid: pid) else { return nil }
            for name in knownNames where output.contains("/\(name)/") {
                living.insert(name)
            }
        }
        return living
    }

    private static func runLSOF(pid: Int32) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-p", String(pid)]
        let outPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = Pipe()
        do {
            try task.run()
        } catch {
            return nil
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8)
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

    /// Inverse of `chromiumDate(from:)` — encodes a `Date` back into
    /// Chromium's own `date_added` format (microseconds since 1601-01-01 UTC).
    private static func chromiumDateString(from date: Date) -> String {
        let microseconds = (date.timeIntervalSince1970 + 11_644_473_600) * 1_000_000
        return String(Int64(microseconds))
    }
}
