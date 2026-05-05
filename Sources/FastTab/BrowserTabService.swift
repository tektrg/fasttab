import Foundation
import AppKit
import OSLog

// ASCII control characters guaranteed not to appear in URLs or page titles.
private let kFieldSep = "\u{1F}" // unit separator
private let kRowSep   = "\u{1C}" // file separator

private func appleScriptQuoted(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}

private func shellQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

private struct ChromiumBrowser: Sendable {
    let appName: String
    let supportDirectory: String
    let bundleIdentifier: String
}

private struct ChromiumProfile: Sendable {
    let browser: ChromiumBrowser
    let name: String
    let directoryURL: URL

    var bookmarksURL: URL { directoryURL.appendingPathComponent("Bookmarks") }
    var historyURL: URL { directoryURL.appendingPathComponent("History") }
    var faviconsURL: URL { directoryURL.appendingPathComponent("Favicons") }
}

@MainActor
class BrowserTabService: ObservableObject {
    @Published var results: [BrowserSearchResult] = []
    @Published var isLoading: Bool = false
    /// True when the fetched live tabs span more than one window (per browser).
    /// Computed from all live tabs, not just the visible prefix, so the flag is
    /// correct even when only a subset is shown in the unfiltered list.
    @Published var hasMultipleWindows: Bool = false

    private let logger = Logger(subsystem: "com.trungluong.FastTab", category: "BrowserTabService")
    private var lastActiveTimes: [String: Date] = [:]
    private var currentFlowSourceAppBundleIdentifier: String?

    private var fetchTask: Task<Void, Never>?
    private var cacheRefreshTask: Task<Void, Never>?

    private var fetchGeneration = 0
    private var lastIssuedQuery: String = ""

    private var cachedBookmarks: [BrowserSearchResult] = []
    private var cachedHistory: [BrowserSearchResult] = []
    private var cacheLastUpdatedAt: Date?
    private var cachedQuickOpenResults: [BrowserSearchResult] = []
    private var cachedQuickOpenSourceAppBundleIdentifier: String?
    private var cachedLiveTabs: [BrowserSearchResult] = []
    private var lastLiveTabsRefreshAt: Date = .distantPast

    private var faviconDataCache: [String: Data] = [:]
    private var faviconImageCache: [String: NSImage] = [:]
    private var faviconLookupTasks: Set<String> = []
    private var faviconPrefetchTask: Task<Void, Never>?

    private let cacheRefreshInterval: TimeInterval = 30
    private let historyCachePerBrowserLimit = 300
    private let initialVisibleTabLimit = 5
    private let typedQueryLiveTabsReuseWindow: TimeInterval = 1.0

    private let browsers: [ChromiumBrowser] = [
        ChromiumBrowser(appName: "Google Chrome", supportDirectory: "~/Library/Application Support/Google/Chrome", bundleIdentifier: "com.google.Chrome"),
        ChromiumBrowser(appName: "Microsoft Edge", supportDirectory: "~/Library/Application Support/Microsoft Edge", bundleIdentifier: "com.microsoft.edgemac")
]

    private nonisolated static func computeHasMultipleWindows(_ tabs: [BrowserSearchResult]) -> Bool {
        var seen = Set<String>()
        for tab in tabs where tab.type == .tab {
            seen.insert(tab.browserName + "|" + String(tab.windowIndex ?? 0))
            if seen.count > 1 { return true }
        }
        return false
    }

    private nonisolated static func typeBreakdown(_ results: [BrowserSearchResult]) -> String {
        let tabs = results.filter { $0.type == .tab }.count
        let bookmarks = results.filter { $0.type == .bookmark }.count
        let history = results.filter { $0.type == .history }.count
        return "total=\(results.count) tabs=\(tabs) bookmarks=\(bookmarks) history=\(history)"
    }

    func prewarmCaches() {
        refreshCachesIfNeeded(force: true)
    }

    func updateCurrentFlowSourceApp(bundleIdentifier: String?) {
        currentFlowSourceAppBundleIdentifier = bundleIdentifier
    }

    func fetchResults(matching query: String = "") {
        fetchGeneration += 1
        let generation = fetchGeneration

        fetchTask?.cancel()

        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentFlowSourceAppBundleIdentifier = self.currentFlowSourceAppBundleIdentifier
        if normalizedQuery.isEmpty, !cachedQuickOpenResults.isEmpty,
           cachedQuickOpenSourceAppBundleIdentifier == currentFlowSourceAppBundleIdentifier {
            results = cachedQuickOpenResults
        }
        isLoading = true

        lastIssuedQuery = normalizedQuery

        let cachedTimes = self.lastActiveTimes
        let browsers = self.browsers
        let bookmarkSnapshot = self.cachedBookmarks
        let historySnapshot = self.cachedHistory
        let initialVisibleTabLimit = self.initialVisibleTabLimit
        let cachedLiveTabsSnapshot = self.cachedLiveTabs
        let lastLiveTabsRefreshAt = self.lastLiveTabsRefreshAt
        let typedQueryLiveTabsReuseWindow = self.typedQueryLiveTabsReuseWindow

        logger.info("fetchResults start. generation=\(generation) query='\(normalizedQuery, privacy: .public)' bookmarkSnapshot=\(bookmarkSnapshot.count) historySnapshot=\(historySnapshot.count)")

        fetchTask = Task.detached(priority: .userInitiated) { [weak self] in
            var updatedTimes = cachedTimes
            let fetchStart = Date()
            var liveTabs: [BrowserSearchResult] = []
            var usedCachedLiveTabs = false

            if !normalizedQuery.isEmpty,
               !cachedLiveTabsSnapshot.isEmpty,
               Date().timeIntervalSince(lastLiveTabsRefreshAt) < typedQueryLiveTabsReuseWindow {
                liveTabs = cachedLiveTabsSnapshot
                usedCachedLiveTabs = true
            } else {
                for browser in browsers {
                    if Task.isCancelled { break }
                    liveTabs.append(contentsOf: Self.fetchTabResults(
                        for: browser,
                        fetchStart: fetchStart,
                        activeTimes: &updatedTimes,
                        currentFlowSourceAppBundleIdentifier: currentFlowSourceAppBundleIdentifier
                    ))
                }
            }

            guard !Task.isCancelled else {
                await MainActor.run {
                    guard let self, generation == self.fetchGeneration else { return }
                    self.isLoading = false
                }
                return
            }

            let sortedLiveTabs = sortBrowserSearchResults(liveTabs)

            if normalizedQuery.isEmpty {
                let prioritizedTabs = quickOpenVisibleTabs(from: sortedLiveTabs, limit: initialVisibleTabLimit)

                await MainActor.run {
                    guard let self, generation == self.fetchGeneration else { return }
                    self.lastActiveTimes = updatedTimes
                    self.results = prioritizedTabs
                    self.cachedQuickOpenResults = prioritizedTabs
                    self.cachedQuickOpenSourceAppBundleIdentifier = currentFlowSourceAppBundleIdentifier
                    self.cachedLiveTabs = sortedLiveTabs
                    self.lastLiveTabsRefreshAt = Date()
                    self.hasMultipleWindows = Self.computeHasMultipleWindows(sortedLiveTabs)
                    self.isLoading = false
                    self.logger.info("fetchResults applied (empty-query fast path). generation=\(generation) topTabs=\(prioritizedTabs.count) liveTabs={\(Self.typeBreakdown(sortedLiveTabs), privacy: .public)}")
                    self.refreshCachesIfNeeded(force: false)
                }
                return
            }

            let tabMatches = sortedLiveTabs.filter { $0.matches(query: normalizedQuery) }
            let bookmarkMatches = bookmarkSnapshot.filter { $0.matches(query: normalizedQuery) }
            let historyMatches = historySnapshot.filter { $0.matches(query: normalizedQuery) }
            let mergedResults = sortBrowserSearchResults(tabMatches + bookmarkMatches + historyMatches)
            let fallbackResults = sortBrowserSearchResults(sortedLiveTabs + bookmarkSnapshot + historySnapshot)
            let fallbackUsed = mergedResults.isEmpty && !fallbackResults.isEmpty
            let finalResults = fallbackUsed ? fallbackResults : mergedResults

            await MainActor.run {
                guard let self, generation == self.fetchGeneration else { return }
                self.lastActiveTimes = updatedTimes
                self.results = finalResults
                if !usedCachedLiveTabs {
                    self.cachedLiveTabs = sortedLiveTabs
                    self.lastLiveTabsRefreshAt = Date()
                    self.hasMultipleWindows = Self.computeHasMultipleWindows(sortedLiveTabs)
                }
                self.isLoading = false
                self.logger.info("fetchResults applied. generation=\(generation) query='\(normalizedQuery, privacy: .public)' liveTabs={\(Self.typeBreakdown(sortedLiveTabs), privacy: .public)} matched={\(Self.typeBreakdown(mergedResults), privacy: .public)} final={\(Self.typeBreakdown(finalResults), privacy: .public)} fallbackUsed=\(fallbackUsed, privacy: .public) usedCachedLiveTabs=\(usedCachedLiveTabs, privacy: .public)")
                self.refreshCachesIfNeeded(force: bookmarkSnapshot.isEmpty && historySnapshot.isEmpty)
            }
        }
    }

    func faviconImage(for result: BrowserSearchResult) -> NSImage? {
        let key = faviconCacheKey(browserName: result.browserName, url: result.url)
        return faviconImageCache[key]
    }

    func preloadFavicons(for results: [BrowserSearchResult], limit: Int) {
        faviconPrefetchTask?.cancel()

        let cappedResults = Array(results.prefix(max(0, limit)))
        let pending = cappedResults.compactMap { result -> (browserName: String, url: String, key: String)? in
            guard let parsedURL = URL(string: result.url),
                  let scheme = parsedURL.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                return nil
            }

            let key = faviconCacheKey(browserName: result.browserName, url: result.url)
            guard faviconDataCache[key] == nil, !faviconLookupTasks.contains(key) else {
                return nil
            }

            return (result.browserName, result.url, key)
        }

        guard !pending.isEmpty else { return }

        for item in pending {
            faviconLookupTasks.insert(item.key)
        }

        let browsers = self.browsers

        faviconPrefetchTask = Task.detached(priority: .utility) { [weak self] in
            var fetched: [(String, Data)] = []

            for item in pending {
                if Task.isCancelled { break }
                if let data = Self.fetchFaviconData(browserName: item.browserName, pageURL: item.url, browsers: browsers) {
                    fetched.append((item.key, data))
                }
            }

            await MainActor.run {
                guard let self else { return }

                for item in pending {
                    self.faviconLookupTasks.remove(item.key)
                }

                guard !fetched.isEmpty else { return }

                for (key, data) in fetched {
                    self.faviconDataCache[key] = data
                    if let image = NSImage(data: data) {
                        self.faviconImageCache[key] = image
                    }
                }
                self.objectWillChange.send()
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

    func copyLinkToClipboard(_ result: BrowserSearchResult) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result.url, forType: .string)
        logger.info("copyLinkToClipboard: copied url='\(result.url, privacy: .public)'")
    }

    func remove(_ result: BrowserSearchResult) {
        switch result.type {
        case .tab:
            closeTab(result)
        case .bookmark:
            deleteBookmark(result)
        case .history:
            deleteHistoryItem(result)
        }

        removeResultFromLocalSnapshots(withID: result.id)
        fetchResults(matching: lastIssuedQuery)
    }

    private func removeResultFromLocalSnapshots(withID resultID: String) {
        results.removeAll { $0.id == resultID }
        cachedQuickOpenResults.removeAll { $0.id == resultID }
        cachedLiveTabs.removeAll { $0.id == resultID }
        cachedBookmarks.removeAll { $0.id == resultID }
        cachedHistory.removeAll { $0.id == resultID }
    }

    private func faviconCacheKey(browserName: String, url: String) -> String {
        guard let parsedURL = URL(string: url), let host = parsedURL.host?.lowercased(), !host.isEmpty else {
            return "\(browserName)|\(url)"
        }
        return "\(browserName)|\(host)"
    }

    private func closeTab(_ result: BrowserSearchResult) {
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

    private func deleteBookmark(_ result: BrowserSearchResult) {
        guard let bookmarkID = result.bookmarkID else {
            logger.error("deleteBookmark: missing bookmarkID for url='\(result.url, privacy: .public)'")
            return
        }

        guard let profile = chromiumProfile(for: result) else {
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
                if deleteBookmarkNode(withID: bookmarkID, from: &node) {
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

    private func deleteHistoryItem(_ result: BrowserSearchResult) {
        guard let profile = chromiumProfile(for: result) else {
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

            guard Self.runProcess(launchPath: "/usr/bin/sqlite3", arguments: [tempURL.path, sql]) != nil else {
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

    private func deleteBookmarkNode(withID bookmarkID: String, from node: inout [String: Any]) -> Bool {
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

    private func browserExecutableURL(for browser: ChromiumBrowser) -> URL? {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleIdentifier) else {
            return nil
        }
        let infoPlistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let infoPlist = NSDictionary(contentsOf: infoPlistURL),
              let executableName = infoPlist["CFBundleExecutable"] as? String else {
            return nil
        }
        return appURL.appendingPathComponent("Contents/MacOS/\(executableName)")
    }

    private func chromiumProfile(for result: BrowserSearchResult) -> ChromiumProfile? {
        guard let browser = browsers.first(where: { $0.appName == result.browserName }) else {
            return nil
        }

        let profiles = Self.chromiumProfiles(for: browser)
        if let profileName = result.profileName {
            return profiles.first(where: { $0.name == profileName })
        }
        return profiles.first
    }

    private func refreshCachesIfNeeded(force: Bool) {
        if !force,
           let cacheLastUpdatedAt,
           Date().timeIntervalSince(cacheLastUpdatedAt) < cacheRefreshInterval {
            let age = Date().timeIntervalSince(cacheLastUpdatedAt)
            self.logger.info("refreshCachesIfNeeded skipped. reason=interval ageSeconds=\(Int(age)) query='\(self.lastIssuedQuery, privacy: .public)'")
            return
        }

        guard cacheRefreshTask == nil else {
            self.logger.info("refreshCachesIfNeeded skipped. reason=task-already-running query='\(self.lastIssuedQuery, privacy: .public)'")
            return
        }

        self.logger.info("refreshCachesIfNeeded start. force=\(force, privacy: .public) query='\(self.lastIssuedQuery, privacy: .public)'")

        let browsers = self.browsers
        let historyLimit = self.historyCachePerBrowserLimit

        cacheRefreshTask = Task(priority: .utility) {
            defer {
                cacheRefreshTask = nil
            }

            let cachePayload = await Task.detached(priority: .utility) {
                let diagnosticLogger = Logger(subsystem: "com.trungluong.FastTab", category: "BrowserTabService")
                var bookmarkResults: [BrowserSearchResult] = []
                var historyResults: [BrowserSearchResult] = []
                var diagnostics: [String] = []

                for browser in browsers {
                    if Task.isCancelled {
                        return (bookmarks: [BrowserSearchResult](), history: [BrowserSearchResult](), diagnostics: [String]())
                    }

                    diagnosticLogger.info("cache-refresh browser start app='\(browser.appName, privacy: .public)'")
                    let browserBookmarks = Self.fetchAllBookmarkResults(for: browser)
                    diagnosticLogger.info("cache-refresh bookmarks app='\(browser.appName, privacy: .public)' count=\(browserBookmarks.count)")
                    let browserHistory = Self.fetchRecentHistoryResults(for: browser, perBrowserLimit: historyLimit)
                    diagnosticLogger.info("cache-refresh history app='\(browser.appName, privacy: .public)' count=\(browserHistory.count)")

                    diagnostics.append("\(browser.appName):bookmarks=\(browserBookmarks.count),history=\(browserHistory.count)")
                    bookmarkResults.append(contentsOf: browserBookmarks)
                    historyResults.append(contentsOf: browserHistory)
                }

                return (
                    bookmarks: sortBrowserSearchResults(bookmarkResults),
                    history: sortBrowserSearchResults(historyResults),
                    diagnostics: diagnostics
                )
            }.value

            if Task.isCancelled { return }

            cachedBookmarks = cachePayload.bookmarks
            cachedHistory = cachePayload.history
            cacheLastUpdatedAt = Date()
            logger.info("Search cache refreshed. bookmarks={\(Self.typeBreakdown(cachePayload.bookmarks), privacy: .public)} history={\(Self.typeBreakdown(cachePayload.history), privacy: .public)} perBrowser='\(cachePayload.diagnostics.joined(separator: "; "), privacy: .public)'")

            if lastIssuedQuery.isEmpty {
                logger.info("Search cache refresh applied without UI refetch (empty query).")
            } else {
                fetchResults(matching: lastIssuedQuery)
            }
        }
    }

    private func activateTab(_ result: BrowserSearchResult) {
        if let key = result.tabRecencyKey {
            lastActiveTimes[key] = Date()
        }

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
        // Try profile-aware opening for Chromium browsers
        if let browser = browsers.first(where: { $0.appName == result.browserName }),
           let profileName = result.profileName,
           let executableURL = browserExecutableURL(for: browser) {
            let executablePath = executableURL.path
            let script = "nohup \(shellQuoted(executablePath)) --profile-directory=\(shellQuoted(profileName)) \(shellQuoted(result.url)) > /dev/null 2>&1 &"
            let task = Process()
            task.launchPath = "/bin/bash"
            task.arguments = ["-c", script]
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
        activeTimes: inout [String: Date],
        currentFlowSourceAppBundleIdentifier: String?
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
                    set windowTitle to title of window w
                    set tabTitles to title of every tab of window w
                    set tabURLs to URL of every tab of window w
                    repeat with t from 1 to count of tabTitles
                        set isActive to (t is equal to activeTabIndex and w is equal to 1) as string
                        set rowData to "\(browser.appName)" & fieldSep & w & fieldSep & t & fieldSep & (item t of tabTitles) & fieldSep & (item t of tabURLs) & fieldSep & isActive & fieldSep & windowTitle
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
            guard parts.count >= 7 else { continue }

            let appName = parts[0]
            let winIdx = Int(parts[1]) ?? 1
            let tabIdx = Int(parts[2]) ?? 1
            let title = parts[3]
            let url = parts[4]
            let isActive = parts[5] == "true"
            let windowName = parts[6]
            let key = makeTabRecencyKey(browserName: appName, windowIndex: winIdx, tabIndex: tabIdx, url: url)
            let isCurrentFlowActiveTab = isActive && browser.bundleIdentifier == currentFlowSourceAppBundleIdentifier
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
                    tabIndex: tabIdx,
                    windowName: windowName,
                    isCurrentFlowActiveTab: isCurrentFlowActiveTab
                )
            )
        }

        return newResults
    }

    private nonisolated static func fetchAllBookmarkResults(for browser: ChromiumBrowser) -> [BrowserSearchResult] {
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
                collectBookmarks(
                    from: node,
                    browserName: browser.appName,
                    profileName: profile.name,
                    folderTrail: [],
                    results: &results
                )
            }
        }

        return results
    }

    private nonisolated static func collectBookmarks(
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

    private nonisolated static func fetchRecentHistoryResults(for browser: ChromiumBrowser, perBrowserLimit: Int) -> [BrowserSearchResult] {
        let logger = Logger(subsystem: "com.trungluong.FastTab", category: "BrowserTabService")
        var dedupedByURL: [String: BrowserSearchResult] = [:]

        for profile in chromiumProfiles(for: browser) {
            guard FileManager.default.fileExists(atPath: profile.historyURL.path) else { continue }
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let profileStart = Date()

            do {
                try FileManager.default.copyItem(at: profile.historyURL, to: tempURL)
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
                    arguments: ["-separator", kFieldSep, tempURL.path, sql],
                    timeoutSeconds: 15
                ) else {
                    logger.error("history profile query failed. browser='\(browser.appName, privacy: .public)' profile='\(profile.name, privacy: .public)'")
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

                let elapsedMs = Int(Date().timeIntervalSince(profileStart) * 1000)
                logger.info("history profile query complete. browser='\(browser.appName, privacy: .public)' profile='\(profile.name, privacy: .public)' rows=\(rows.count) elapsedMs=\(elapsedMs)")
                try? FileManager.default.removeItem(at: tempURL)
            } catch {
                logger.error("history profile query threw. browser='\(browser.appName, privacy: .public)' profile='\(profile.name, privacy: .public)' error='\(String(describing: error), privacy: .public)'")
                try? FileManager.default.removeItem(at: tempURL)
            }
        }

        return dedupedByURL.values
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(perBrowserLimit)
            .map { $0 }
    }

    private nonisolated static func fetchFaviconData(browserName: String, pageURL: String, browsers: [ChromiumBrowser]) -> Data? {
        guard let browser = browsers.first(where: { $0.appName == browserName }) else {
            return nil
        }

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

        for profile in chromiumProfiles(for: browser) {
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

    private nonisolated static func dataFromHex(_ hex: String) -> Data? {
        let compact = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty, compact.count.isMultiple(of: 2) else { return nil }

        var data = Data(capacity: compact.count / 2)
        var index = compact.startIndex

        while index < compact.endIndex {
            let next = compact.index(index, offsetBy: 2)
            let byteString = compact[index..<next]
            guard let byte = UInt8(byteString, radix: 16) else { return nil }
            data.append(byte)
            index = next
        }

        return data
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

    private nonisolated static func chromiumDate(from rawValue: String?) -> Date? {
        guard let rawValue, let microseconds = Double(rawValue) else { return nil }
        return Date(timeIntervalSince1970: (microseconds / 1_000_000) - 11_644_473_600)
    }

    private nonisolated static func chromiumDate(fromSQLiteValue rawValue: String) -> Date? {
        guard let microseconds = Double(rawValue) else { return nil }
        return Date(timeIntervalSince1970: (microseconds / 1_000_000) - 11_644_473_600)
    }

    private nonisolated static func runProcess(launchPath: String, arguments: [String], timeoutSeconds: TimeInterval = 4) -> String? {
        let logger = Logger(subsystem: "com.trungluong.FastTab", category: "BrowserTabService")
        let task = Process()
        task.launchPath = launchPath
        task.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        task.standardOutput = stdoutPipe
        task.standardError = stderrPipe

        do {
            try task.run()

            let deadline = Date().addingTimeInterval(timeoutSeconds)
            while task.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }

            if task.isRunning {
                task.terminate()
                logger.error("runProcess timeout. launchPath='\(launchPath, privacy: .public)' timeoutSeconds=\(timeoutSeconds)")
                return nil
            }

            guard task.terminationStatus == 0 else {
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
                logger.error("runProcess failed. launchPath='\(launchPath, privacy: .public)' status=\(task.terminationStatus) stderr='\(stderrText, privacy: .public)'")
                return nil
            }

            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            logger.error("runProcess threw. launchPath='\(launchPath, privacy: .public)' error='\(String(describing: error), privacy: .public)'")
            return nil
        }
    }
}
