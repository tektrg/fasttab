import Foundation
import AppKit
import OSLog
import CryptoKit

struct SafariBackend: BrowserBackend {
    let appName: String = "Safari"
    let bundleIdentifier: String = "com.apple.Safari"

    static let includeFDADataDefaultsKey = "FastTab.safari.includeFDAData"

    private var logger: Logger {
        Logger(subsystem: "com.trungluong.FastTab", category: "SafariBackend")
    }

    private var fdaEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.includeFDADataDefaultsKey)
    }

    // MARK: - Live tabs

    func fetchLiveTabs(
        fetchStart: Date,
        activeTimes: inout [String: Date],
        currentFlowSourceAppBundleIdentifier: String?
    ) -> [BrowserSearchResult] {
        let script = """
        tell application "Safari"
            if it is not running then return ""
            set fieldSep to (ASCII character 31)
            set rowSep to (ASCII character 28)
            set tabData to ""
            try
                set winCount to count of windows
                repeat with w from 1 to winCount
                    try
                        set currentTabRef to current tab of window w
                        set windowTitle to name of window w
                        set tabList to tabs of window w
                        repeat with t from 1 to count of tabList
                            try
                                set thisTab to item t of tabList
                                set isActive to (thisTab is currentTabRef) as string
                                set tabName to name of thisTab
                                set tabURL to URL of thisTab
                                if tabURL is missing value then set tabURL to ""
                                if tabName is missing value then set tabName to tabURL
                                set rowData to "Safari" & fieldSep & w & fieldSep & t & fieldSep & tabName & fieldSep & tabURL & fieldSep & isActive & fieldSep & windowTitle
                                if tabData is "" then
                                    set tabData to rowData
                                else
                                    set tabData to tabData & rowSep & rowData
                                end if
                            on error
                                -- skip tab on error
                            end try
                        end repeat
                    on error
                        -- skip window on error
                    end try
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
        logger.info("recency-sort fetchLiveTabs start. browser='Safari' activeTimesCount=\(activeTimesCount) rows=\(rows.count)")
        for row in rows where !row.isEmpty {
            let parts = row.components(separatedBy: kFieldSep)
            guard parts.count >= 7 else { continue }

            let browserName = parts[0]
            let winIdx = Int(parts[1]) ?? 1
            let tabIdx = Int(parts[2]) ?? 1
            let title = parts[3]
            let url = parts[4]
            guard !url.isEmpty else { continue }
            let isActive = parts[5] == "true"
            let windowName = parts[6]
            let hasMediaIndicator = browserWindowMediaIndicatorBelongsToTab(tabTitle: title, windowName: windowName)
            let key = makeTabRecencyKey(browserName: browserName, windowIndex: winIdx, tabIndex: tabIdx, url: url)
            let isFrontActive = isActive && winIdx == 1 && bundleIdentifier == currentFlowSourceAppBundleIdentifier
            let isCurrentFlowActiveTab = isFrontActive
            let storedTime = activeTimes[key]
            let timestamp: Date = {
                if isFrontActive { return fetchStart }
                return storedTime ?? Date(timeIntervalSince1970: 0)
            }()
            logger.info("recency-sort tab. browser='\(browserName, privacy: .public)' win=\(winIdx) tab=\(tabIdx) isActive=\(isActive, privacy: .public) isFrontActive=\(isFrontActive, privacy: .public) hadStoredTime=\(storedTime != nil, privacy: .public) storedEpoch=\(storedTime?.timeIntervalSince1970 ?? -1) chosenEpoch=\(timestamp.timeIntervalSince1970) key='\(key, privacy: .public)' title='\(title, privacy: .public)'")

            if isFrontActive {
                activeTimes[key] = fetchStart
            }

            newResults.append(
                BrowserSearchResult(
                    title: title,
                    url: url,
                    browserName: browserName,
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
        // Only stamp the active tab of the FRONT window (window 1).
        let script = """
        tell application "Safari"
            if it is not running then return ""
            if (count of windows) is 0 then return ""
            set fieldSep to (ASCII character 31)
            try
                set currentTabRef to current tab of window 1
                set tabIdx to index of currentTabRef
                set activeURL to URL of currentTabRef
                if activeURL is missing value then return ""
                return "1" & fieldSep & tabIdx & fieldSep & activeURL
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
        guard fdaEnabled else { return [] }

        let path = ("~/Library/Safari/Bookmarks.plist" as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: path)

        guard let data = try? Data(contentsOf: url) else {
            logger.info("safari bookmarks: file not readable (FDA?) path=\(path, privacy: .public)")
            return []
        }

        var format: PropertyListSerialization.PropertyListFormat = .binary
        guard let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any] else {
            logger.error("safari bookmarks: failed to parse plist")
            return []
        }

        var results: [BrowserSearchResult] = []
        Self.collectSafariBookmarks(from: root, browserName: appName, folderTrail: [], results: &results)
        return results
    }

    private static func collectSafariBookmarks(
        from node: [String: Any],
        browserName: String,
        folderTrail: [String],
        results: inout [BrowserSearchResult]
    ) {
        let nodeType = node["WebBookmarkType"] as? String

        if nodeType == "WebBookmarkTypeLeaf" {
            guard let urlString = node["URLString"] as? String, !urlString.isEmpty else { return }
            let title: String = {
                if let dict = node["URIDictionary"] as? [String: Any],
                   let t = dict["title"] as? String, !t.isEmpty {
                    return t
                }
                return urlString
            }()

            results.append(
                BrowserSearchResult(
                    title: title,
                    url: urlString,
                    browserName: browserName,
                    type: .bookmark,
                    timestamp: Date(timeIntervalSince1970: 0),
                    bookmarkID: nil,
                    profileName: nil,
                    folderPath: folderTrail.joined(separator: " / ")
                )
            )
            return
        }

        // List/folder or root: recurse into Children
        let folderTitle = (node["Title"] as? String) ?? ""
        let isList = nodeType == "WebBookmarkTypeList"
        // Skip pseudo-folders like BookmarksBar / BookmarksMenu name? Keep all titled folders.
        let nextTrail: [String]
        if isList, !folderTitle.isEmpty {
            nextTrail = folderTrail + [folderTitle]
        } else {
            nextTrail = folderTrail
        }

        guard let children = node["Children"] as? [[String: Any]] else { return }
        for child in children {
            collectSafariBookmarks(from: child, browserName: browserName, folderTrail: nextTrail, results: &results)
        }
    }

    // MARK: - History

    func fetchRecentHistory(perBrowserLimit: Int) -> [BrowserSearchResult] {
        guard fdaEnabled else { return [] }

        let historyPath = ("~/Library/Safari/History.db" as NSString).expandingTildeInPath
        let historyURL = URL(fileURLWithPath: historyPath)
        guard FileManager.default.fileExists(atPath: historyPath) else {
            logger.info("safari history: db missing at path=\(historyPath, privacy: .public)")
            return []
        }

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-SafariHistory.db")

        do {
            try Self.copySQLiteDBWithWAL(from: historyURL, to: tempURL)
            defer { Self.cleanupSQLiteCopy(at: tempURL) }

            let sql = """
            SELECT hi.url, COALESCE(hv.title, hi.url) as title, MAX(hv.visit_time) as last_visit
            FROM history_items hi
            JOIN history_visits hv ON hv.history_item = hi.id
            WHERE hi.url IS NOT NULL AND hi.url != ''
            GROUP BY hi.id
            ORDER BY last_visit DESC
            LIMIT \(perBrowserLimit);
            """

            guard let output = runProcess(
                launchPath: "/usr/bin/sqlite3",
                arguments: ["-separator", kFieldSep, tempURL.path, sql],
                timeoutSeconds: 15
            ) else {
                logger.error("safari history query failed.")
                return []
            }

            var results: [BrowserSearchResult] = []
            let rows = output.split(separator: "\n", omittingEmptySubsequences: true)
            for row in rows {
                let parts = String(row).components(separatedBy: kFieldSep)
                guard parts.count >= 3 else { continue }

                let url = parts[0]
                let title = parts[1].isEmpty ? url : parts[1]
                let timestamp = Self.safariDate(fromSQLiteValue: parts[2]) ?? Date(timeIntervalSince1970: 0)

                results.append(
                    BrowserSearchResult(
                        title: title,
                        url: url,
                        browserName: appName,
                        type: .history,
                        timestamp: timestamp,
                        profileName: nil
                    )
                )
            }

            logger.info("safari history loaded. app=\(appName, privacy: .public) count=\(results.count)")
            return results
        } catch {
            Self.cleanupSQLiteCopy(at: tempURL)
            logger.error("safari history threw. error='\(String(describing: error), privacy: .public)'")
            return []
        }
    }

    func searchHistory(query: String, limit: Int) -> [BrowserSearchResult] {
        guard fdaEnabled else { return [] }

        let historyPath = ("~/Library/Safari/History.db" as NSString).expandingTildeInPath
        let historyURL = URL(fileURLWithPath: historyPath)
        guard FileManager.default.fileExists(atPath: historyPath) else { return [] }

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-SafariHistory.db")

        do {
            try Self.copySQLiteDBWithWAL(from: historyURL, to: tempURL)
            defer { Self.cleanupSQLiteCopy(at: tempURL) }

            let escaped = query.replacingOccurrences(of: "'", with: "''")
            let sql = """
            SELECT hi.url, COALESCE(hv.title, hi.url) as title, MAX(hv.visit_time) as last_visit
            FROM history_items hi
            JOIN history_visits hv ON hv.history_item = hi.id
            WHERE (hi.url LIKE '%\(escaped)%' OR hv.title LIKE '%\(escaped)%')
              AND hi.url IS NOT NULL AND hi.url != ''
            GROUP BY hi.id
            ORDER BY last_visit DESC
            LIMIT \(limit);
            """

            guard let output = runProcess(
                launchPath: "/usr/bin/sqlite3",
                arguments: ["-separator", kFieldSep, tempURL.path, sql],
                timeoutSeconds: 15
            ) else {
                logger.error("safari searchHistory query failed.")
                return []
            }

            var results: [BrowserSearchResult] = []
            let rows = output.split(separator: "\n", omittingEmptySubsequences: true)
            for row in rows {
                let parts = String(row).components(separatedBy: kFieldSep)
                guard parts.count >= 3 else { continue }

                let url = parts[0]
                let title = parts[1].isEmpty ? url : parts[1]
                let timestamp = Self.safariDate(fromSQLiteValue: parts[2]) ?? Date(timeIntervalSince1970: 0)

                results.append(BrowserSearchResult(
                    title: title,
                    url: url,
                    browserName: appName,
                    type: .history,
                    timestamp: timestamp,
                    profileName: nil
                ))
            }

            logger.info("safari searchHistory complete. count=\(results.count)")
            return results
        } catch {
            Self.cleanupSQLiteCopy(at: tempURL)
            logger.error("safari searchHistory threw. error='\(String(describing: error), privacy: .public)'")
            return []
        }
    }

    // MARK: - WAL-aware SQLite copy

    /// Copies a SQLite DB plus its `-wal` and `-shm` sidecars to the destination
    /// (preserving the basename relationship). Safari's `History.db` and `favicons.db`
    /// are WAL-mode; copying only the main file yields an inconsistent snapshot that
    /// sqlite3 cannot read.
    private static func copySQLiteDBWithWAL(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        try fm.copyItem(at: source, to: destination)
        let walSrc = source.deletingPathExtension().appendingPathExtension("\(source.pathExtension)-wal")
        let shmSrc = source.deletingPathExtension().appendingPathExtension("\(source.pathExtension)-shm")
        let walSrcAlt = URL(fileURLWithPath: source.path + "-wal")
        let shmSrcAlt = URL(fileURLWithPath: source.path + "-shm")
        let walDst = URL(fileURLWithPath: destination.path + "-wal")
        let shmDst = URL(fileURLWithPath: destination.path + "-shm")

        for (src, dst) in [(walSrcAlt, walDst), (shmSrcAlt, shmDst), (walSrc, walDst), (shmSrc, shmDst)] {
            guard fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dst.path) else { continue }
            try? fm.copyItem(at: src, to: dst)
        }
    }

    private static func cleanupSQLiteCopy(at destination: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        try? fm.removeItem(at: URL(fileURLWithPath: destination.path + "-wal"))
        try? fm.removeItem(at: URL(fileURLWithPath: destination.path + "-shm"))
    }

    // MARK: - Favicons

    func fetchFaviconData(pageURL: String) -> Data? {
        guard fdaEnabled else { return nil }

        let cacheDir = ("~/Library/Safari/Favicon Cache" as NSString).expandingTildeInPath
        let dbPath = (cacheDir as NSString).appendingPathComponent("favicons.db")
        // Bitmaps live in `favicons/<MD5(icon_info.uuid as UTF-8 string, with hyphens) uppercase hex>`.
        let imagesDir = (cacheDir as NSString).appendingPathComponent("favicons")
        guard FileManager.default.fileExists(atPath: dbPath) else {
            logger.info("safari favicon: db missing at '\(dbPath, privacy: .public)'")
            return nil
        }

        guard let parsed = URL(string: pageURL),
              let host = parsed.host?.lowercased(), !host.isEmpty else {
            return nil
        }

        let escapedURL = pageURL.replacingOccurrences(of: "'", with: "''")
        // Build the set of plausible "bare host" URL spellings Safari may have stored
        // for the homepage. Observed in the wild: with and without trailing slash,
        // with and without `www.`, http and https.
        let sqlHost = host.replacingOccurrences(of: "'", with: "''")
        let bareHosts = [sqlHost, "www.\(sqlHost)"]
        let bareSchemes = ["https", "http"]
        var exactCandidates: [String] = [escapedURL]
        for s in bareSchemes {
            for h in bareHosts {
                exactCandidates.append("\(s)://\(h)")
                exactCandidates.append("\(s)://\(h)/")
            }
        }
        let exactList = exactCandidates.map { "'\($0)'" }.joined(separator: ",")

        // LIKE pattern: escape % and _ in host so subdomains don't accidentally match.
        let likeEscapedHost = host
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
            .replacingOccurrences(of: "'", with: "''")
        let originLikeHTTPS = "https://\(likeEscapedHost)/%"
        let originLikeHTTP = "http://\(likeEscapedHost)/%"
        let originLikeHTTPSWWW = "https://www.\(likeEscapedHost)/%"
        let originLikeHTTPWWW = "http://www.\(likeEscapedHost)/%"

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-SafariFavicons.db")

        do {
            try Self.copySQLiteDBWithWAL(from: URL(fileURLWithPath: dbPath), to: tempURL)
            defer { Self.cleanupSQLiteCopy(at: tempURL) }

            // Safari schema (varies by macOS version): `page_url(url, uuid)` is the only
            // table we rely on. Earlier versions also had `icon_info(uuid, host, ...)`
            // but on recent macOS the `host` column is gone, so we only match via
            // `page_url`: exact URL → origin URL → any URL under the same host.
            // Bitmaps live on disk at Favicon Cache/Images/<uuid>.png — NOT in the DB.
            // Resolve page → uuid. Bitmap filename is the uuid with hyphens stripped
            // (uppercase hex), in `favicons/`.
            let sql = """
            SELECT uuid FROM page_url WHERE url IN (\(exactList)) LIMIT 1;
            SELECT uuid FROM page_url
              WHERE url LIKE '\(originLikeHTTPS)' ESCAPE '\\'
                 OR url LIKE '\(originLikeHTTP)' ESCAPE '\\'
                 OR url LIKE '\(originLikeHTTPSWWW)' ESCAPE '\\'
                 OR url LIKE '\(originLikeHTTPWWW)' ESCAPE '\\'
              ORDER BY length(url) ASC
              LIMIT 1;
            """

            guard let output = runProcess(
                launchPath: "/usr/bin/sqlite3",
                arguments: [tempURL.path, sql],
                timeoutSeconds: 6
            ) else {
                logger.info("safari favicon: sqlite3 failed host='\(host, privacy: .public)'")
                return nil
            }

            let uuids = output
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            guard !uuids.isEmpty else {
                logger.info("safari favicon: no uuid for host='\(host, privacy: .public)'")
                return nil
            }

            for uuid in uuids {
                // Bitmap filename on macOS 26+: uppercase-hex MD5 of the uuid string
                // (hyphens included), as UTF-8. No extension. Lives in `favicons/`.
                let digest = Insecure.MD5.hash(data: Data(uuid.utf8))
                let name = digest.map { String(format: "%02X", $0) }.joined()
                let imagePath = (imagesDir as NSString).appendingPathComponent(name)
                if let data = try? Data(contentsOf: URL(fileURLWithPath: imagePath)), !data.isEmpty {
                    return data
                }
            }

            logger.info("safari favicon: image file missing for uuids=\(uuids.joined(separator: ","), privacy: .public) host='\(host, privacy: .public)'")
            return nil
        } catch {
            Self.cleanupSQLiteCopy(at: tempURL)
            logger.error("safari favicon: threw error='\(String(describing: error), privacy: .public)'")
            return nil
        }
    }

    func fetchFaviconsBatch(pageURLs: [String]) -> [String: Data] {
        guard fdaEnabled, !pageURLs.isEmpty else { return [:] }

        let cacheDir = ("~/Library/Safari/Favicon Cache" as NSString).expandingTildeInPath
        let dbPath = (cacheDir as NSString).appendingPathComponent("favicons.db")
        let imagesDir = (cacheDir as NSString).appendingPathComponent("favicons")
        guard FileManager.default.fileExists(atPath: dbPath) else { return [:] }

        // For each page URL, build the set of URL spellings Safari may have stored.
        var candidateToOriginals: [String: [String]] = [:]
        for page in pageURLs {
            guard let parsed = URL(string: page),
                  let host = parsed.host?.lowercased(), !host.isEmpty else { continue }
            var candidates: Set<String> = [page]
            for scheme in ["https", "http"] {
                for h in [host, "www.\(host)"] {
                    candidates.insert("\(scheme)://\(h)")
                    candidates.insert("\(scheme)://\(h)/")
                }
            }
            for c in candidates {
                candidateToOriginals[c, default: []].append(page)
            }
        }
        guard !candidateToOriginals.isEmpty else { return [:] }

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-SafariFavicons.db")
        do {
            try Self.copySQLiteDBWithWAL(from: URL(fileURLWithPath: dbPath), to: tempURL)
            defer { Self.cleanupSQLiteCopy(at: tempURL) }

            let inList = candidateToOriginals.keys
                .map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }
                .joined(separator: ",")
            let sql = "SELECT url, uuid FROM page_url WHERE url IN (\(inList));"

            guard let output = runProcess(
                launchPath: "/usr/bin/sqlite3",
                arguments: ["-separator", kFieldSep, tempURL.path, sql],
                timeoutSeconds: 8
            ), !output.isEmpty else {
                return [:]
            }

            // For each original page, pick the first uuid found (exact-URL match wins
            // because we append page itself before origin variants in the candidate set).
            var pageToUUID: [String: String] = [:]
            for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
                let parts = line.split(separator: Character(kFieldSep), maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 2 else { continue }
                let matchedURL = parts[0]
                let uuid = parts[1]
                guard let originals = candidateToOriginals[matchedURL] else { continue }
                for orig in originals where pageToUUID[orig] == nil {
                    pageToUUID[orig] = uuid
                }
            }

            // Read each bitmap once, share across pages that resolved to the same uuid.
            var uuidToData: [String: Data] = [:]
            var result: [String: Data] = [:]
            for (page, uuid) in pageToUUID {
                if let cached = uuidToData[uuid] {
                    result[page] = cached
                    continue
                }
                let digest = Insecure.MD5.hash(data: Data(uuid.utf8))
                let name = digest.map { String(format: "%02X", $0) }.joined()
                let imagePath = (imagesDir as NSString).appendingPathComponent(name)
                if let data = try? Data(contentsOf: URL(fileURLWithPath: imagePath)), !data.isEmpty {
                    uuidToData[uuid] = data
                    result[page] = data
                }
            }
            return result
        } catch {
            Self.cleanupSQLiteCopy(at: tempURL)
            logger.error("safari favicon batch: threw error='\(String(describing: error), privacy: .public)'")
            return [:]
        }
    }

    // MARK: - Actions

    func activateTab(_ result: BrowserSearchResult) {
        let safeURL = appleScriptQuoted(result.url)
        let fallbackWindow = max(1, result.windowIndex ?? 1)
        let fallbackTab = max(1, result.tabIndex ?? 1)

        let script = """
        tell application "Safari"
            activate
            set targetURL to "\(safeURL)"
            set foundMatch to false
            try
                set winCount to count of windows
                repeat with w from 1 to winCount
                    set tabList to tabs of window w
                    repeat with i from 1 to count of tabList
                        try
                            set thisURL to URL of item i of tabList
                            if thisURL is equal to targetURL then
                                set current tab of window w to item i of tabList
                                set index of window w to 1
                                set foundMatch to true
                                exit repeat
                            end if
                        end try
                    end repeat
                    if foundMatch then exit repeat
                end repeat
            end try
            if foundMatch is false then
                try
                    set current tab of window \(fallbackWindow) to tab \(fallbackTab) of window \(fallbackWindow)
                    set index of window \(fallbackWindow) to 1
                end try
            end if
        end tell
        """

        logger.info("activateTab: app=Safari title='\(result.title, privacy: .public)' url='\(result.url, privacy: .public)'")
        runAppleScript(script, logger: logger, action: "activateTab")
    }

    func closeTab(_ result: BrowserSearchResult) {
        let safeURL = appleScriptQuoted(result.url)
        let fallbackWindow = max(1, result.windowIndex ?? 1)
        let fallbackTab = max(1, result.tabIndex ?? 1)

        let script = """
        tell application "Safari"
            if it is not running then return
            set targetURL to "\(safeURL)"
            set didClose to false
            try
                set winCount to count of windows
                repeat with w from 1 to winCount
                    set tabList to tabs of window w
                    repeat with i from 1 to count of tabList
                        try
                            set thisURL to URL of item i of tabList
                            if thisURL is equal to targetURL then
                                close tab i of window w
                                set didClose to true
                                exit repeat
                            end if
                        end try
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

        logger.info("closeTab: app=Safari title='\(result.title, privacy: .public)' url='\(result.url, privacy: .public)'")
        runAppleScript(script, logger: logger, action: "closeTab")
    }

    func openURL(_ result: BrowserSearchResult) {
        let safeURL = appleScriptQuoted(result.url)
        let script = """
        tell application "Safari"
            activate
            open location "\(safeURL)"
        end tell
        """

        logger.info("openURL: app=Safari type=\(result.type.rawValue, privacy: .public) url='\(result.url, privacy: .public)'")
        runAppleScript(script, logger: logger, action: "openURL")
    }

    func deleteBookmark(_ result: BrowserSearchResult) {
        logger.info("deleteBookmark: Safari is read-only, no-op for url='\(result.url, privacy: .public)'")
    }

    func deleteHistoryItem(_ result: BrowserSearchResult) {
        logger.info("deleteHistoryItem: Safari is read-only, no-op for url='\(result.url, privacy: .public)'")
    }

    // MARK: - Helpers

    /// Safari `visit_time` is stored as seconds since 2001-01-01 UTC (Cocoa epoch).
    private static func safariDate(fromSQLiteValue rawValue: String) -> Date? {
        guard let seconds = Double(rawValue) else { return nil }
        return Date(timeIntervalSinceReferenceDate: seconds)
    }
}
