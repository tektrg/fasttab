import Foundation
import AppKit
import OSLog
import ApplicationServices

enum SafariAutomationStatus: String, Sendable {
    case notInstalled
    case granted
    case denied
    case notDetermined
}

@MainActor
class BrowserTabService: ObservableObject {
    @Published var results: [BrowserSearchResult] = []
    @Published var isLoading: Bool = false
    /// True when the fetched live tabs span more than one window (per browser).
    @Published var hasMultipleWindows: Bool = false
    @Published private(set) var openTabCount: Int = 0
    @Published private(set) var hasFetchedOpenTabCount: Bool = false
    @Published private(set) var safariAutomationStatus: SafariAutomationStatus = .notDetermined

    private let logger = Logger(subsystem: "com.trungluong.FastTab", category: "BrowserTabService")
    private var lastActiveTimes: [String: Date] = [:]
    private var currentFlowSourceAppBundleIdentifier: String?

    private var fetchTask: Task<Void, Never>?
    private var cacheRefreshTask: Task<Void, Never>?

    private var fetchGeneration = 0
    private var lastIssuedQuery: String = ""
    private var lastIssuedFilter: ScopeFilter = ScopeFilter()

    private(set) var cachedBookmarks: [BrowserSearchResult] = []
    private var cachedHistory: [BrowserSearchResult] = []
    private var cacheLastUpdatedAt: Date?
    private var cachedQuickOpenResults: [BrowserSearchResult] = []
    private var cachedQuickOpenSourceAppBundleIdentifier: String?
    private(set) var cachedLiveTabs: [BrowserSearchResult] = []
    private var lastLiveTabsRefreshAt: Date = .distantPast

    private struct ClosedTabTombstone {
        let browserName: String
        let url: String
        let timestamp: Date
    }
    private var recentlyClosedTabs: [ClosedTabTombstone] = []
    private let closedTabTombstoneTTL: TimeInterval = 3.0

    private var faviconDataCache: [String: Data] = [:]
    private var faviconImageCache: [String: NSImage] = [:]
    private var faviconLookupTasks: Set<String> = []
    private var faviconPrefetchTask: Task<Void, Never>?

    private let cacheRefreshInterval: TimeInterval = 30
    private let historyCachePerBrowserLimit = 300
    private let initialVisibleTabLimit = 5
    private let typedQueryLiveTabsReuseWindow: TimeInterval = 1.0

    private let backends: [any BrowserBackend]

    private static let activeTimesDefaultsKey = "FastTab.lastActiveTimes"

    // Background poll of active tabs (frontmost browser only).
    private let activeTabPollInterval: TimeInterval = 10
    private var activeTabPollTimer: Timer?
    private var activeTabPollInFlight = false
    private var sleepObservers: [NSObjectProtocol] = []
    // Throttle UserDefaults writes triggered by the 10s poll. Bar-open and
    // close-tab paths still persist immediately.
    private let pollPersistInterval: TimeInterval = 60
    private var lastPollPersistAt: Date = .distantPast

    init() {
        var backends: [any BrowserBackend] = [
            ChromiumBackend(
                appName: "Google Chrome",
                bundleIdentifier: "com.google.Chrome",
                supportDirectory: "~/Library/Application Support/Google/Chrome"
            ),
            ChromiumBackend(
                appName: "Microsoft Edge",
                bundleIdentifier: "com.microsoft.edgemac",
                supportDirectory: "~/Library/Application Support/Microsoft Edge"
            )
        ]

        if Self.isSafariInstalled() {
            backends.append(SafariBackend())
        }

        self.backends = backends
        self.lastActiveTimes = Self.loadActiveTimes()
        self.safariAutomationStatus = Self.probeSafariAutomation()
        logger.info("BrowserTabService init. backends=\(backends.map { $0.appName }.joined(separator: ","), privacy: .public) safariAutomation=\(self.safariAutomationStatus.rawValue, privacy: .public)")
        startActiveTabPoll()
    }

    // MARK: - Active-tab poll

    private func startActiveTabPoll() {
        let timer = Timer(timeInterval: activeTabPollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tickActiveTabPoll()
            }
        }
        timer.tolerance = 2.0
        RunLoop.main.add(timer, forMode: .common)
        activeTabPollTimer = timer

        let nc = NSWorkspace.shared.notificationCenter
        sleepObservers.append(
            nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.suspendActiveTabPoll() }
            }
        )
        sleepObservers.append(
            nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.resumeActiveTabPoll() }
            }
        )
    }

    private func suspendActiveTabPoll() {
        activeTabPollTimer?.invalidate()
        activeTabPollTimer = nil
        logger.info("active-tab poll suspended (sleep).")
    }

    private func resumeActiveTabPoll() {
        guard activeTabPollTimer == nil else { return }
        let timer = Timer(timeInterval: activeTabPollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tickActiveTabPoll()
            }
        }
        timer.tolerance = 2.0
        RunLoop.main.add(timer, forMode: .common)
        activeTabPollTimer = timer
        logger.info("active-tab poll resumed (wake).")
    }

    private func tickActiveTabPoll() {
        guard !activeTabPollInFlight else { return }

        guard let frontBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return }
        guard let backend = backends.first(where: { $0.bundleIdentifier == frontBundleID }) else { return }

        activeTabPollInFlight = true
        let backendRef = backend
        Task.detached(priority: .utility) { [weak self] in
            let stamp = Date()
            let keys = backendRef.pollActiveTabKeys()
            await MainActor.run {
                guard let self else { return }
                self.activeTabPollInFlight = false
                guard !keys.isEmpty else { return }
                for key in keys {
                    self.lastActiveTimes[key] = stamp
                }
                // Throttle disk writes from the high-frequency poll. In-memory
                // state is always current; persistence catches up at most once
                // per pollPersistInterval. Bar-open / close-tab paths still
                // call persistActiveTimes() directly for immediate durability.
                if Date().timeIntervalSince(self.lastPollPersistAt) >= self.pollPersistInterval {
                    self.persistActiveTimes()
                    self.lastPollPersistAt = Date()
                }
                self.logger.info("active-tab poll tick. browser='\(backendRef.appName, privacy: .public)' keys=\(keys.count)")
            }
        }
    }

    // MARK: - Safari probes

    private static func isSafariInstalled() -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") != nil
    }

    private static func probeSafariAutomation() -> SafariAutomationStatus {
        guard isSafariInstalled() else { return .notInstalled }

        var addrDesc = AEAddressDesc()
        let bundleID = "com.apple.Safari"
        let createStatus: OSErr = bundleID.withCString { cstr in
            AECreateDesc(
                DescType(typeApplicationBundleID),
                cstr,
                Int(strlen(cstr)),
                &addrDesc
            )
        }
        guard createStatus == noErr else { return .notDetermined }
        defer { AEDisposeDesc(&addrDesc) }

        let result = AEDeterminePermissionToAutomateTarget(&addrDesc, typeWildCard, typeWildCard, false)
        switch Int(result) {
        case Int(noErr):
            return .granted
        case Int(errAEEventNotPermitted):
            return .denied
        case -1744: // errAEEventWouldRequireUserConsent
            return .notDetermined
        default:
            return .notDetermined
        }
    }

    func recheckSafariAutomation() {
        safariAutomationStatus = Self.probeSafariAutomation()
        logger.info("recheckSafariAutomation status=\(self.safariAutomationStatus.rawValue, privacy: .public)")
    }

    /// Probes whether the running process has Full Disk Access to Safari's
    /// protected data. Reads a small prefix of `History.db`; permission errors
    /// surface as `false`. Lightweight enough to call on Settings focus.
    func canReadSafariProtectedData() -> Bool {
        let path = (("~/Library/Safari/History.db" as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: path) else { return false }
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return false
        }
        defer { try? handle.close() }
        do {
            _ = try handle.read(upToCount: 16)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Persistence

    private static func loadActiveTimes() -> [String: Date] {
        guard let raw = UserDefaults.standard.dictionary(forKey: activeTimesDefaultsKey) as? [String: Double] else {
            return [:]
        }
        return raw.mapValues { Date(timeIntervalSince1970: $0) }
    }

    private func persistActiveTimes() {
        let raw = lastActiveTimes.mapValues { $0.timeIntervalSince1970 }
        UserDefaults.standard.set(raw, forKey: Self.activeTimesDefaultsKey)
    }

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

    // MARK: - Scope sources

    /// Distinct windows present in the most recent live-tabs snapshot, sorted
    /// by browser name then window index. Used by the `in:` dropdown.
    var availableWindows: [WindowRef] {
        var seen: Set<String> = []
        var out: [WindowRef] = []
        for tab in cachedLiveTabs where tab.type == .tab {
            let name = tab.windowName ?? ""
            let idx = tab.windowIndex ?? 0
            let ref = WindowRef(browserName: tab.browserName, windowName: name, windowIndex: idx)
            if seen.insert(ref.id).inserted {
                out.append(ref)
            }
        }
        return out.sorted { lhs, rhs in
            if lhs.browserName != rhs.browserName {
                return lhs.browserName.localizedCompare(rhs.browserName) == .orderedAscending
            }
            return lhs.windowIndex < rhs.windowIndex
        }
    }

    /// Distinct bookmark folders present in the cached bookmarks snapshot.
    var availableBookmarkFolders: [BookmarkFolderRef] {
        var seen: Set<String> = []
        var out: [BookmarkFolderRef] = []
        for bm in cachedBookmarks where bm.type == .bookmark {
            guard let path = bm.folderPath, !path.isEmpty else { continue }
            let ref = BookmarkFolderRef(
                browserName: bm.browserName,
                profileName: bm.profileName,
                folderPath: path
            )
            if seen.insert(ref.id).inserted {
                out.append(ref)
            }
        }
        return out.sorted { lhs, rhs in
            lhs.folderPath.localizedCaseInsensitiveCompare(rhs.folderPath) == .orderedAscending
        }
    }

    func fetchResults(matching query: String = "", filter: ScopeFilter = ScopeFilter()) {
        // Remember the last filter so internal triggers (tab close, cache
        // refresh) preserve any active scope.
        lastIssuedFilter = filter
        guard !filter.isPassthrough else {
            fetchResultsUnscoped(matching: query)
            return
        }
        fetchScopedResults(matching: query, filter: filter)
    }

    private func fetchScopedResults(matching query: String, filter: ScopeFilter) {
        fetchGeneration += 1
        let generation = fetchGeneration
        fetchTask?.cancel()

        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        lastIssuedQuery = normalizedQuery

        guard filter.isSatisfiable else {
            results = []
            isLoading = false
            logger.info("fetchScopedResults short-circuit (unsatisfiable). generation=\(generation)")
            return
        }

        isLoading = true

        let backends = self.backends
        let cachedTimes = self.lastActiveTimes
        let bookmarkSnapshot = self.cachedBookmarks
        let currentFlowSourceAppBundleIdentifier = self.currentFlowSourceAppBundleIdentifier
        let requiredType = filter.requiredType

        fetchTask = Task.detached(priority: .userInitiated) { [weak self] in
            var updatedTimes = cachedTimes
            var produced: [BrowserSearchResult] = []

            switch requiredType {
            case .tab:
                // Live tabs (always fresh — scope-aware fetches don't reuse cache).
                var liveTabs: [BrowserSearchResult] = []
                for backend in backends {
                    if Task.isCancelled { break }
                    liveTabs.append(contentsOf: backend.fetchLiveTabs(
                        fetchStart: Date(),
                        activeTimes: &updatedTimes,
                        currentFlowSourceAppBundleIdentifier: currentFlowSourceAppBundleIdentifier
                    ))
                }
                liveTabs = sortBrowserSearchResults(liveTabs)
                if filter.duplicateOnly {
                    // Duplicates are scoped per-browser: same URL open in Chrome
                    // and Safari is not surprising and shouldn't be flagged.
                    var counts: [String: Int] = [:]
                    for tab in liveTabs where tab.type == .tab {
                        let key = tab.browserName + "|" + tab.url
                        counts[key, default: 0] += 1
                    }
                    liveTabs = liveTabs.filter { (counts[$0.browserName + "|" + $0.url] ?? 0) >= 2 }
                }
                produced = liveTabs.filter { filter.matches($0) }

            case .bookmark:
                produced = bookmarkSnapshot.filter { filter.matches($0) }

            case .history:
                let limit = 500
                let since = filter.historySince
                let before = filter.historyBefore
                let collected: [BrowserSearchResult] = await withTaskGroup(of: [BrowserSearchResult].self) { group in
                    for backend in backends {
                        group.addTask {
                            backend.searchHistory(query: normalizedQuery, limit: limit, since: since, before: before)
                        }
                    }
                    var all: [BrowserSearchResult] = []
                    for await chunk in group { all.append(contentsOf: chunk) }
                    return all
                }
                produced = sortBrowserSearchResults(collected).filter { filter.matches($0) }

            case .none:
                produced = []
            }

            // Apply free-text filter (history is already query-filtered at SQL).
            if !normalizedQuery.isEmpty, requiredType != .history {
                produced = produced.filter { $0.matches(query: normalizedQuery) }
            }

            await MainActor.run {
                guard let self, generation == self.fetchGeneration else { return }
                self.lastActiveTimes = updatedTimes
                self.persistActiveTimes()
                // Refresh live-tabs cache if we just fetched fresh ones.
                if requiredType == .tab {
                    let freshLive = sortBrowserSearchResults(produced.filter { $0.type == .tab })
                    // Only refresh cache when not duplicate-only (which is a filtered subset).
                    if !filter.duplicateOnly && filter.window == nil {
                        self.cachedLiveTabs = freshLive
                        self.lastLiveTabsRefreshAt = Date()
                        self.hasMultipleWindows = Self.computeHasMultipleWindows(freshLive)
                        self.openTabCount = freshLive.count
                        self.hasFetchedOpenTabCount = true
                    }
                }
                self.results = self.filteringRecentlyClosed(produced)
                self.isLoading = false
                self.logger.info("fetchScopedResults applied. generation=\(generation) type=\(String(describing: requiredType), privacy: .public) query='\(normalizedQuery, privacy: .public)' count=\(produced.count)")
                // Bookmarks scope: if cache empty, force a refresh so the next call has data.
                self.refreshCachesIfNeeded(force: requiredType == .bookmark && bookmarkSnapshot.isEmpty)
            }
        }
    }

    private func fetchResultsUnscoped(matching query: String = "") {
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
        let backends = self.backends
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
                for backend in backends {
                    if Task.isCancelled { break }
                    liveTabs.append(contentsOf: backend.fetchLiveTabs(
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
            let recencyTopPreview = sortedLiveTabs.prefix(10).map { r -> String in
                "[win=\(r.windowIndex ?? -1) tab=\(r.tabIndex ?? -1) ts=\(Int(r.timestamp.timeIntervalSince1970)) '\(r.title.prefix(40))']"
            }.joined(separator: " ")
            Logger(subsystem: "com.trungluong.FastTab", category: "BrowserTabService").info("recency-sort post-sort top10. generation=\(generation) usedCachedLiveTabs=\(usedCachedLiveTabs, privacy: .public) liveTabsCount=\(sortedLiveTabs.count) top='\(recencyTopPreview, privacy: .public)'")

            if normalizedQuery.isEmpty {
                let prioritizedTabs = quickOpenVisibleTabs(from: sortedLiveTabs, limit: initialVisibleTabLimit)

                await MainActor.run {
                    guard let self, generation == self.fetchGeneration else { return }
                    let filteredLiveTabs = self.filteringRecentlyClosed(sortedLiveTabs)
                    let filteredPrioritized = self.filteringRecentlyClosed(prioritizedTabs)
                    self.lastActiveTimes = updatedTimes
                    self.persistActiveTimes()
                    self.results = filteredPrioritized
                    self.cachedQuickOpenResults = filteredPrioritized
                    self.cachedQuickOpenSourceAppBundleIdentifier = currentFlowSourceAppBundleIdentifier
                    self.cachedLiveTabs = filteredLiveTabs
                    self.lastLiveTabsRefreshAt = Date()
                    self.hasMultipleWindows = Self.computeHasMultipleWindows(filteredLiveTabs)
                    self.openTabCount = filteredLiveTabs.count
                    self.hasFetchedOpenTabCount = true
                    self.isLoading = false
                    self.logger.info("fetchResults applied (empty-query fast path). generation=\(generation) topTabs=\(filteredPrioritized.count) liveTabs={\(Self.typeBreakdown(filteredLiveTabs), privacy: .public)}")
                    self.refreshCachesIfNeeded(force: false)
                }
                return
            }

            let tabMatches = sortedLiveTabs.filter { $0.matches(query: normalizedQuery) }
            let bookmarkMatches = bookmarkSnapshot.filter { $0.matches(query: normalizedQuery) }

            // Phase 1: publish tabs + bookmarks immediately so UI isn't blocked by history DB I/O
            let phase1Results = sortBrowserSearchResults(tabMatches + bookmarkMatches)
            await MainActor.run {
                guard let self, generation == self.fetchGeneration else { return }
                let filteredLiveTabs = self.filteringRecentlyClosed(sortedLiveTabs)
                let filteredPhase1 = self.filteringRecentlyClosed(phase1Results)
                self.lastActiveTimes = updatedTimes
                self.persistActiveTimes()
                if !usedCachedLiveTabs {
                    self.cachedLiveTabs = filteredLiveTabs
                    self.lastLiveTabsRefreshAt = Date()
                    self.hasMultipleWindows = Self.computeHasMultipleWindows(filteredLiveTabs)
                    self.openTabCount = filteredLiveTabs.count
                    self.hasFetchedOpenTabCount = true
                }
                if !filteredPhase1.isEmpty {
                    self.results = filteredPhase1
                }
                self.logger.info("fetchResults phase1 applied. generation=\(generation) query='\(normalizedQuery, privacy: .public)' phase1={\(Self.typeBreakdown(filteredPhase1), privacy: .public)}")
            }

            guard !Task.isCancelled else {
                await MainActor.run {
                    guard let self, generation == self.fetchGeneration else { return }
                    self.isLoading = false
                }
                return
            }

            // Phase 2: run history search per backend concurrently
            let historyMatches = await withTaskGroup(of: [BrowserSearchResult].self) { group in
                for backend in backends {
                    group.addTask { backend.searchHistory(query: normalizedQuery, limit: 500) }
                }
                var all: [BrowserSearchResult] = []
                for await chunk in group { all.append(contentsOf: chunk) }
                return all
            }

            let mergedResults = sortBrowserSearchResults(tabMatches + bookmarkMatches + historyMatches)
            let fallbackResults = sortBrowserSearchResults(sortedLiveTabs + bookmarkSnapshot + historySnapshot)
            let fallbackUsed = mergedResults.isEmpty && !fallbackResults.isEmpty
            let finalResults = fallbackUsed ? fallbackResults : mergedResults

            await MainActor.run {
                guard let self, generation == self.fetchGeneration else { return }
                let filteredFinal = self.filteringRecentlyClosed(finalResults)
                self.results = filteredFinal
                self.isLoading = false
                self.logger.info("fetchResults phase2 applied. generation=\(generation) query='\(normalizedQuery, privacy: .public)' history=\(historyMatches.count) final={\(Self.typeBreakdown(filteredFinal), privacy: .public)} fallbackUsed=\(fallbackUsed, privacy: .public)")
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

        let backends = self.backends

        faviconPrefetchTask = Task.detached(priority: .utility) { [weak self] in
            var fetched: [(String, Data)] = []

            let byBrowser = Dictionary(grouping: pending, by: { $0.browserName })
            for (browserName, items) in byBrowser {
                if Task.isCancelled { break }
                guard let backend = backends.first(where: { $0.appName == browserName }) else { continue }
                let urls = items.map { $0.url }
                let resolved = backend.fetchFaviconsBatch(pageURLs: urls)
                for item in items {
                    if let data = resolved[item.url] {
                        fetched.append((item.key, data))
                    }
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
            if let key = result.tabRecencyKey {
                let now = Date()
                lastActiveTimes[key] = now
                persistActiveTimes()
                logger.info("recency-sort activate persisted. key='\(key, privacy: .public)' epoch=\(now.timeIntervalSince1970) totalKeys=\(self.lastActiveTimes.count) title='\(result.title, privacy: .public)'")
            } else {
                logger.info("recency-sort activate skipped (no recency key). title='\(result.title, privacy: .public)' type=\(String(describing: result.type), privacy: .public)")
            }
            backend(for: result)?.activateTab(result)
        case .bookmark, .history:
            backend(for: result)?.openURL(result)
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
            backend(for: result)?.closeTab(result)
            recentlyClosedTabs.append(
                ClosedTabTombstone(browserName: result.browserName, url: result.url, timestamp: Date())
            )
        case .bookmark:
            backend(for: result)?.deleteBookmark(result)
        case .history:
            backend(for: result)?.deleteHistoryItem(result)
        }

        removeResultFromLocalSnapshots(matching: result)
        fetchResults(matching: lastIssuedQuery, filter: lastIssuedFilter)
    }

    private func removeResultFromLocalSnapshots(matching result: BrowserSearchResult) {
        let resultID = result.id
        switch result.type {
        case .tab:
            // Indices can shift after a close, so match tabs by (browser, url) with
            // "consume one" semantics — only the first matching tab in each list is removed,
            // preserving duplicates that may legitimately exist in other windows.
            removeFirstTab(in: &results, browserName: result.browserName, url: result.url)
            removeFirstTab(in: &cachedQuickOpenResults, browserName: result.browserName, url: result.url)
            removeFirstTab(in: &cachedLiveTabs, browserName: result.browserName, url: result.url)
        case .bookmark, .history:
            results.removeAll { $0.id == resultID }
            cachedQuickOpenResults.removeAll { $0.id == resultID }
            cachedBookmarks.removeAll { $0.id == resultID }
            cachedHistory.removeAll { $0.id == resultID }
        }
        openTabCount = cachedLiveTabs.count
    }

    private func removeFirstTab(in list: inout [BrowserSearchResult], browserName: String, url: String) {
        if let idx = list.firstIndex(where: { $0.type == .tab && $0.browserName == browserName && $0.url == url }) {
            list.remove(at: idx)
        }
    }

    private func pruneClosedTabTombstones() {
        let cutoff = Date().addingTimeInterval(-closedTabTombstoneTTL)
        recentlyClosedTabs.removeAll { $0.timestamp < cutoff }
    }

    /// Filters out tabs that were recently closed by the user but may still appear in a fresh
    /// live-tab fetch because the browser's scriptable tab list hasn't caught up yet. Uses
    /// "consume one match per tombstone" so legitimate duplicate URLs in other windows survive.
    private func filteringRecentlyClosed(_ tabs: [BrowserSearchResult]) -> [BrowserSearchResult] {
        pruneClosedTabTombstones()
        guard !recentlyClosedTabs.isEmpty else { return tabs }
        var remaining = recentlyClosedTabs
        var out: [BrowserSearchResult] = []
        out.reserveCapacity(tabs.count)
        for tab in tabs {
            if tab.type == .tab,
               let idx = remaining.firstIndex(where: { $0.browserName == tab.browserName && $0.url == tab.url }) {
                remaining.remove(at: idx)
                continue
            }
            out.append(tab)
        }
        return out
    }

    private func faviconCacheKey(browserName: String, url: String) -> String {
        guard let parsedURL = URL(string: url), let host = parsedURL.host?.lowercased(), !host.isEmpty else {
            return "\(browserName)|\(url)"
        }
        return "\(browserName)|\(host)"
    }

    private func backend(for result: BrowserSearchResult) -> (any BrowserBackend)? {
        backends.first(where: { $0.appName == result.browserName })
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

        let backends = self.backends
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

                for backend in backends {
                    if Task.isCancelled {
                        return (bookmarks: [BrowserSearchResult](), history: [BrowserSearchResult](), diagnostics: [String]())
                    }

                    diagnosticLogger.info("cache-refresh browser start app='\(backend.appName, privacy: .public)'")
                    let browserBookmarks = backend.fetchAllBookmarks()
                    diagnosticLogger.info("cache-refresh bookmarks app='\(backend.appName, privacy: .public)' count=\(browserBookmarks.count)")
                    let browserHistory = backend.fetchRecentHistory(perBrowserLimit: historyLimit)
                    diagnosticLogger.info("cache-refresh history app='\(backend.appName, privacy: .public)' count=\(browserHistory.count)")

                    diagnostics.append("\(backend.appName):bookmarks=\(browserBookmarks.count),history=\(browserHistory.count)")
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
                fetchResults(matching: lastIssuedQuery, filter: lastIssuedFilter)
            }
        }
    }
}
