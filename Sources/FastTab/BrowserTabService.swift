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
    /// Frecency store keyed by `Frecency.key(browser, profile, normalizedURL)`.
    /// Parallel to `lastActiveTimes` — `lastActiveTimes` still drives the per-tab
    /// `timestamp` shown in row UI; `frecency` drives the tab-tier sort order.
    private var frecency: [String: FrecencyEntry] = [:]
    /// Tracks the last-observed front-tab frecency key per browser. Used by the
    /// 10s poll to debounce dwell — only the *transition* to a new front tab
    /// counts as a visit, not every tick on the same tab.
    private var lastPolledFrontFrecencyKey: [String: String] = [:]
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
    private let historyCachePerBrowserLimit = 1000
    private let initialVisibleTabLimit = 5
    private let typedQueryLiveTabsReuseWindow: TimeInterval = 1.0

    private let backends: [any BrowserBackend]

    private static let activeTimesDefaultsKey = "FastTab.lastActiveTimes"
    private static let frecencyDefaultsKey = "FastTab.frecencyV1"

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
        let enabled = SourceSelectionStore.shared.enabled
        var backends: [any BrowserBackend] = []

        if enabled.contains(.chrome) {
            backends.append(ChromiumBackend(
                appName: "Google Chrome",
                bundleIdentifier: "com.google.Chrome",
                supportDirectory: "~/Library/Application Support/Google/Chrome"
            ))
        }
        if enabled.contains(.edge) {
            backends.append(ChromiumBackend(
                appName: "Microsoft Edge",
                bundleIdentifier: "com.microsoft.edgemac",
                supportDirectory: "~/Library/Application Support/Microsoft Edge"
            ))
        }
        if enabled.contains(.brave) {
            backends.append(ChromiumBackend(
                // appName must match Brave's AppleScript target and `.app`
                // bundle name ("Brave Browser"), not the colloquial "Brave".
                appName: "Brave Browser",
                bundleIdentifier: "com.brave.Browser",
                supportDirectory: "~/Library/Application Support/BraveSoftware/Brave-Browser"
            ))
        }
        if enabled.contains(.safari), Self.isSafariInstalled() {
            backends.append(SafariBackend())
        }
        if enabled.contains(.finder) {
            backends.append(FinderBackend())
        }

        self.backends = backends
        self.lastActiveTimes = Self.loadActiveTimes()
        let backendAppNames = backends.map { $0.appName }
        self.frecency = Self.loadFrecency(
            seedFromLegacy: self.lastActiveTimes,
            backendAppNames: backendAppNames
        )
        // Skip the TCC-touching probe when the user has not opted into Safari
        // — there's no point asking macOS about Automation we won't use.
        self.safariAutomationStatus = enabled.contains(.safari)
            ? Self.probeSafariAutomation()
            : .notInstalled
        logger.info("BrowserTabService init. backends=\(backendAppNames.joined(separator: ","), privacy: .public) safariAutomation=\(self.safariAutomationStatus.rawValue, privacy: .public) frecencyEntries=\(self.frecency.count)")
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
                // Frecency: record a visit only on front-tab *transition*
                // (key change since last poll), so a tab left foregrounded
                // doesn't accumulate one visit per tick.
                let browserName = backendRef.appName
                if let url = Self.urlFromCompositeRecencyKey(keys[0], browserName: browserName) {
                    let frecencyKey = Frecency.key(browser: browserName, profile: nil, url: url)
                    let previous = self.lastPolledFrontFrecencyKey[browserName]
                    if previous != frecencyKey {
                        self.lastPolledFrontFrecencyKey[browserName] = frecencyKey
                        self.recordVisit(frecencyKey: frecencyKey, now: stamp)
                    }
                }
                // Throttle disk writes from the high-frequency poll. In-memory
                // state is always current; persistence catches up at most once
                // per pollPersistInterval. Bar-open / close-tab paths still
                // call persistActiveTimes() directly for immediate durability.
                if Date().timeIntervalSince(self.lastPollPersistAt) >= self.pollPersistInterval {
                    self.persistActiveTimes()
                    self.persistFrecency()
                    self.lastPollPersistAt = Date()
                }
                self.logger.info("active-tab poll tick. browser='\(backendRef.appName, privacy: .public)' keys=\(keys.count) frecencyEntries=\(self.frecency.count)")
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

    // MARK: - Frecency

    /// Loads the persisted frecency dict. On first run after upgrade (no
    /// `frecencyV1` data) seeds entries from the legacy `lastActiveTimes`
    /// composite-key dict so users don't lose their recency history. Evicts
    /// entries older than the eviction threshold during load.
    private static func loadFrecency(
        seedFromLegacy legacy: [String: Date],
        backendAppNames: [String]
    ) -> [String: FrecencyEntry] {
        let defaults = UserDefaults.standard
        let now = Date()
        var out: [String: FrecencyEntry] = [:]

        if let data = defaults.data(forKey: frecencyDefaultsKey),
           let decoded = try? JSONDecoder().decode([String: FrecencyEntry].self, from: data) {
            for (key, entry) in decoded where !Frecency.shouldEvict(entry, now: now) {
                out[key] = entry
            }
            return out
        }

        // First-run migration. Parse `browser|win|tab|url` and seed a single-
        // visit entry per (browser, normalizedURL). Multiple legacy keys may
        // collapse to the same frecency key — accumulate by taking max
        // lastVisit and summing count.
        for (legacyKey, ts) in legacy {
            guard let parsed = parseLegacyRecencyKey(legacyKey, backendAppNames: backendAppNames) else { continue }
            let fkey = Frecency.key(browser: parsed.browser, profile: nil, url: parsed.url)
            if var existing = out[fkey] {
                existing.count += 1
                if ts > existing.lastVisit {
                    existing.lastVisit = ts
                }
                existing.cachedScore = existing.count
                existing.cachedScoreAt = ts
                out[fkey] = existing
            } else {
                out[fkey] = FrecencyEntry(
                    count: 1.0,
                    lastVisit: ts,
                    cachedScore: 1.0,
                    cachedScoreAt: ts
                )
            }
        }
        out = out.filter { !Frecency.shouldEvict($0.value, now: now) }
        return out
    }

    private func persistFrecency() {
        // Evict stale entries before write so the on-disk size stays bounded.
        let now = Date()
        frecency = frecency.filter { !Frecency.shouldEvict($0.value, now: now) }
        if let data = try? JSONEncoder().encode(frecency) {
            UserDefaults.standard.set(data, forKey: Self.frecencyDefaultsKey)
        }
    }

    /// Mutates the frecency dict to record a visit at `frecencyKey`. Caller is
    /// responsible for persisting (immediate for activate/close paths, throttled
    /// for the 10s poll).
    private func recordVisit(frecencyKey: String, weight: Double = 1.0, now: Date = Date()) {
        if var existing = frecency[frecencyKey] {
            Frecency.applyVisit(&existing, weight: weight, now: now)
            frecency[frecencyKey] = existing
        } else {
            frecency[frecencyKey] = Frecency.newEntry(weight: weight, now: now)
        }
    }

    /// Returns the cached score for the URL/browser of `result`. Zero when no
    /// entry exists (treated as the lowest priority tier within tabs). O(1)
    /// arithmetic; safe to call from sort closures over thousands of items.
    private func frecencyScore(for result: BrowserSearchResult) -> Double {
        // For lookup, try both (browser, profile, url) and the collapsed
        // (browser, *, url). Profile may have been set when the entry was
        // written but not available now, or vice versa — prefer the more
        // specific match.
        if let profile = result.profileName, !profile.isEmpty {
            let specific = Frecency.key(browser: result.browserName, profile: profile, url: result.url)
            if let entry = frecency[specific] {
                return Frecency.liveScore(entry)
            }
        }
        let collapsed = Frecency.key(browser: result.browserName, profile: nil, url: result.url)
        if let entry = frecency[collapsed] {
            return Frecency.liveScore(entry)
        }
        return 0
    }

    /// Returns a sendable score-lookup closure that captures a snapshot of
    /// the current frecency dict. Safe to pass into `Task.detached` since the
    /// dict is value-copied.
    private func makeFrecencyScoreLookup() -> @Sendable (BrowserSearchResult) -> Double {
        let snapshot = frecency
        return { result in
            if let profile = result.profileName, !profile.isEmpty {
                let specific = Frecency.key(browser: result.browserName, profile: profile, url: result.url)
                if let entry = snapshot[specific] {
                    return Frecency.liveScore(entry)
                }
            }
            let collapsed = Frecency.key(browser: result.browserName, profile: nil, url: result.url)
            if let entry = snapshot[collapsed] {
                return Frecency.liveScore(entry)
            }
            return 0
        }
    }

    /// Parses a legacy `browser|win|tab|url` recency key. browserName may
    /// contain spaces but not `|`, so `browser` is matched against the known
    /// backend names. Returns nil for malformed keys.
    private static func parseLegacyRecencyKey(
        _ key: String,
        backendAppNames: [String]
    ) -> (browser: String, url: String)? {
        // Sort longest-first so "Microsoft Edge" matches before "Edge" etc.
        let sorted = backendAppNames.sorted { $0.count > $1.count }
        guard let browser = sorted.first(where: { key.hasPrefix($0 + "|") }) else { return nil }
        // Strip "<browser>|<win>|<tab>|" prefix; URL is the remainder.
        let afterBrowser = key.dropFirst(browser.count + 1)
        let parts = afterBrowser.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let url = String(parts[2])
        guard !url.isEmpty else { return nil }
        return (browser, url)
    }

    /// Extracts URL from a composite recency key returned by
    /// `backend.pollActiveTabKeys()`. Mirrors `parseLegacyRecencyKey` but
    /// scoped to a known browser name (avoids prefix-disambiguation).
    private static func urlFromCompositeRecencyKey(_ key: String, browserName: String) -> String? {
        guard key.hasPrefix(browserName + "|") else { return nil }
        let afterBrowser = key.dropFirst(browserName.count + 1)
        let parts = afterBrowser.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let url = String(parts[2])
        return url.isEmpty ? nil : url
    }

    /// Fan out `fetchLiveTabs` across `backends` in parallel.
    ///
    /// The legacy sequential loop made every cold fetch wait for the slowest
    /// AppleScript-driven backend in series — adding the Finder backend made
    /// this worse because `target of w as alias` can stall on sleeping NAS /
    /// SMB shares. Parallel fan-out converts the cost from additive
    /// (sum of backend latencies) to overlapping (max of backend latencies).
    ///
    /// Each task gets a *private* copy of `baseline` to mutate, then returns
    /// the delta. The merge applies max-timestamp wins (writes only ever
    /// advance time — see ChromiumBackend / FinderBackend, which write
    /// `fetchStart` only for the current-flow front tab). This keeps the
    /// semantics identical to the sequential loop without needing a shared
    /// `inout` across tasks.
    ///
    /// Single-backend case (e.g. source-pinned scope) bypasses the task-group
    /// to avoid Swift concurrency overhead when there's nothing to overlap.
    private nonisolated static func fetchLiveTabsParallel(
        backends: [any BrowserBackend],
        fetchStart: Date,
        baseline: [String: Date],
        activeTimes: inout [String: Date],
        currentFlowSourceAppBundleIdentifier: String?
    ) async -> [BrowserSearchResult] {
        if backends.isEmpty { return [] }
        if backends.count == 1 {
            return backends[0].fetchLiveTabs(
                fetchStart: fetchStart,
                activeTimes: &activeTimes,
                currentFlowSourceAppBundleIdentifier: currentFlowSourceAppBundleIdentifier
            )
        }

        let collected = await withTaskGroup(
            of: (tabs: [BrowserSearchResult], updates: [String: Date]).self
        ) { group in
            for backend in backends {
                group.addTask {
                    if Task.isCancelled { return ([], [:]) }
                    var local = baseline
                    let tabs = backend.fetchLiveTabs(
                        fetchStart: fetchStart,
                        activeTimes: &local,
                        currentFlowSourceAppBundleIdentifier: currentFlowSourceAppBundleIdentifier
                    )
                    // Diff vs baseline so we don't ship the whole dict across
                    // task boundaries. In practice updates is 0-1 entries per
                    // backend (only the current-flow front tab is rewritten).
                    var updates: [String: Date] = [:]
                    for (key, value) in local where baseline[key] != value {
                        updates[key] = value
                    }
                    return (tabs, updates)
                }
            }
            var all: [(tabs: [BrowserSearchResult], updates: [String: Date])] = []
            for await item in group { all.append(item) }
            return all
        }

        var liveTabs: [BrowserSearchResult] = []
        for entry in collected {
            liveTabs.append(contentsOf: entry.tabs)
            for (key, value) in entry.updates {
                if let existing = activeTimes[key] {
                    if value > existing { activeTimes[key] = value }
                } else {
                    activeTimes[key] = value
                }
            }
        }
        return liveTabs
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
        for tab in cachedLiveTabs where tab.type == .tab && tab.browserName != "Finder" {
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

        let allBackends = self.backends
        let cachedTimes = self.lastActiveTimes
        let bookmarkSnapshot = self.cachedBookmarks
        let currentFlowSourceAppBundleIdentifier = self.currentFlowSourceAppBundleIdentifier
        let requiredType = filter.requiredType
        let pinnedSource = filter.source
        let frecencyLookup = makeFrecencyScoreLookup()

        // Source-pinned scope: only the matching backend runs. Saves us from
        // polling Chrome via AppleScript and reading the Safari history DB
        // when the user has explicitly asked for, e.g., Finder only. Matches
        // the CLAUDE.md "no wasted work in fetch path" rule.
        let backends: [any BrowserBackend]
        if let pinnedSource {
            backends = allBackends.filter { $0.appName == pinnedSource }
        } else {
            backends = allBackends
        }

        fetchTask = Task.detached(priority: .userInitiated) { [weak self] in
            var updatedTimes = cachedTimes
            var produced: [BrowserSearchResult] = []

            switch requiredType {
            case .tab:
                // Live tabs (always fresh — scope-aware fetches don't reuse cache).
                var liveTabs = await Self.fetchLiveTabsParallel(
                    backends: backends,
                    fetchStart: Date(),
                    baseline: cachedTimes,
                    activeTimes: &updatedTimes,
                    currentFlowSourceAppBundleIdentifier: currentFlowSourceAppBundleIdentifier
                )
                liveTabs = sortBrowserSearchResults(liveTabs, frecencyScore: frecencyLookup)
                if filter.duplicateOnly {
                    // Duplicates are scoped per-browser: same URL open in Chrome
                    // and Safari is not surprising and shouldn't be flagged.
                    // Normalize URLs before counting so minor variations
                    // (trailing slash, case differences) don't defeat detection.
                    var counts: [String: Int] = [:]
                    for tab in liveTabs where tab.type == .tab {
                        let key = tab.browserName + "|" + Self.normalizeDuplicateURL(tab.url)
                        counts[key, default: 0] += 1
                    }
                    liveTabs = liveTabs.filter { (counts[$0.browserName + "|" + Self.normalizeDuplicateURL($0.url)] ?? 0) >= 2 }
                }
                produced = liveTabs.filter { filter.matches($0) }

            case .bookmark:
                produced = bookmarkSnapshot.filter { filter.matches($0) }

            case .history:
                let limit = 1000
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
                produced = sortBrowserSearchResults(collected, frecencyScore: frecencyLookup).filter { filter.matches($0) }

            case .none:
                // Source-only scope (e.g. `@Finder` alone, no required type).
                // Merge live tabs + history from the pinned backend(s) so the
                // user sees everything the source has to offer in one list,
                // with the existing tab-tier > history-tier sort.
                if pinnedSource != nil {
                    let liveTabs = await Self.fetchLiveTabsParallel(
                        backends: backends,
                        fetchStart: Date(),
                        baseline: cachedTimes,
                        activeTimes: &updatedTimes,
                        currentFlowSourceAppBundleIdentifier: currentFlowSourceAppBundleIdentifier
                    )
                    // Publish tabs immediately so they're never blocked by the
                    // history DB read below — mirrors the phase-1/phase-2 split
                    // in fetchResultsUnscoped. History merges in at the shared
                    // publish at the end of this task.
                    let earlyTabs = sortBrowserSearchResults(liveTabs, frecencyScore: frecencyLookup)
                        .filter { filter.matches($0) }
                    await MainActor.run {
                        guard let self, generation == self.fetchGeneration else { return }
                        self.results = self.filteringRecentlyClosed(earlyTabs)
                        self.isLoading = false
                    }
                    let history: [BrowserSearchResult] = await withTaskGroup(of: [BrowserSearchResult].self) { group in
                        for backend in backends {
                            group.addTask {
                                backend.searchHistory(query: normalizedQuery, limit: 1000)
                            }
                        }
                        var all: [BrowserSearchResult] = []
                        for await chunk in group { all.append(contentsOf: chunk) }
                        return all
                    }
                    // De-dup: suppress a history row whose URL is currently
                    // open as a live tab in the same source — design call,
                    // avoids the user seeing the same path twice when they
                    // pin to Finder.
                    let liveURLs = Set(liveTabs.map { $0.url })
                    let dedupedHistory = history.filter { !liveURLs.contains($0.url) }
                    let merged = liveTabs + dedupedHistory
                    produced = sortBrowserSearchResults(merged, frecencyScore: frecencyLookup)
                        .filter { filter.matches($0) }
                } else {
                    produced = []
                }
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
                    let freshLive = sortBrowserSearchResults(produced.filter { $0.type == .tab }, frecencyScore: frecencyLookup)
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
        let frecencyLookup = makeFrecencyScoreLookup()

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
                liveTabs = await Self.fetchLiveTabsParallel(
                    backends: backends,
                    fetchStart: fetchStart,
                    baseline: cachedTimes,
                    activeTimes: &updatedTimes,
                    currentFlowSourceAppBundleIdentifier: currentFlowSourceAppBundleIdentifier
                )
            }

            guard !Task.isCancelled else {
                await MainActor.run {
                    guard let self, generation == self.fetchGeneration else { return }
                    self.isLoading = false
                }
                return
            }

            // Empty query (quick-open top-5) must rank by raw recency so the
            // tab you *just* used is always at the top — a hard UX guarantee
            // that frecency would violate (a daily-driver gmail tab would
            // outrank the tab you alt-tabbed to 5 seconds ago). Typed-query
            // paths below re-sort with frecency.
            //
            // Empty-query fast path: only the top-N rows are rendered, and
            // `cachedLiveTabs` is consumed downstream as an unordered set
            // (count, hasMultipleWindows, re-sort by typed-query). So we skip
            // the full O(n log n) sort and compute just top-K (O(n log k)).
            let sortedLiveTabs: [BrowserSearchResult]
            let quickOpenTopK: [BrowserSearchResult]?
            if normalizedQuery.isEmpty {
                // Filter the current-flow active tab *before* top-K so we
                // always return `initialVisibleTabLimit` rows (the active
                // tab would otherwise eat a slot, then be stripped later).
                let candidates = liveTabs.filter { !$0.isCurrentFlowActiveTab }
                quickOpenTopK = topKTabsByRecency(candidates, limit: initialVisibleTabLimit)
                sortedLiveTabs = liveTabs  // unordered; consumers don't need order
            } else {
                sortedLiveTabs = sortBrowserSearchResults(liveTabs, frecencyScore: frecencyLookup)
                quickOpenTopK = nil
            }
            let recencyTopPreview = (quickOpenTopK ?? sortedLiveTabs).prefix(10).map { r -> String in
                "[win=\(r.windowIndex ?? -1) tab=\(r.tabIndex ?? -1) ts=\(Int(r.timestamp.timeIntervalSince1970)) '\(r.title.prefix(40))']"
            }.joined(separator: " ")
            Logger(subsystem: "com.trungluong.FastTab", category: "BrowserTabService").info("recency-sort post-sort top10. generation=\(generation) usedCachedLiveTabs=\(usedCachedLiveTabs, privacy: .public) liveTabsCount=\(sortedLiveTabs.count) top='\(recencyTopPreview, privacy: .public)'")

            if normalizedQuery.isEmpty {
                let prioritizedTabs = quickOpenTopK ?? []

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
            let phase1Results = sortBrowserSearchResults(tabMatches + bookmarkMatches, frecencyScore: frecencyLookup)
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
                self.results = filteredPhase1
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
                    group.addTask { backend.searchHistory(query: normalizedQuery, limit: 1000) }
                }
                var all: [BrowserSearchResult] = []
                for await chunk in group { all.append(contentsOf: chunk) }
                return all
            }

            let mergedResults = sortBrowserSearchResults(tabMatches + bookmarkMatches + historyMatches, frecencyScore: frecencyLookup)

            await MainActor.run {
                guard let self, generation == self.fetchGeneration else { return }
                let filteredFinal = self.filteringRecentlyClosed(mergedResults)
                self.results = filteredFinal
                self.isLoading = false
                self.logger.info("fetchResults phase2 applied. generation=\(generation) query='\(normalizedQuery, privacy: .public)' history=\(historyMatches.count) final={\(Self.typeBreakdown(filteredFinal), privacy: .public)}")
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
            let now = Date()
            if let key = result.tabRecencyKey {
                lastActiveTimes[key] = now
                persistActiveTimes()
                logger.info("recency-sort activate persisted. key='\(key, privacy: .public)' epoch=\(now.timeIntervalSince1970) totalKeys=\(self.lastActiveTimes.count) title='\(result.title, privacy: .public)'")
            } else {
                logger.info("recency-sort activate skipped (no recency key). title='\(result.title, privacy: .public)' type=\(String(describing: result.type), privacy: .public)")
            }
            // Frecency: every user-driven activation is a full-weight visit.
            let frecencyKey = Frecency.key(
                browser: result.browserName,
                profile: result.profileName,
                url: result.url
            )
            recordVisit(frecencyKey: frecencyKey, now: now)
            persistFrecency()
            lastPolledFrontFrecencyKey[result.browserName] = frecencyKey
            logger.info("frecency activate. key='\(frecencyKey, privacy: .public)' score=\(self.frecency[frecencyKey].map { Frecency.liveScore($0) } ?? 0) totalEntries=\(self.frecency.count)")
            // Dispatch the AppleScript-driven activation off the main thread —
            // `runAppleScript` is synchronous and can stall (TCC prompt, slow
            // alias resolution, modal save dialog). Blocking @MainActor here
            // would freeze the UI for the duration. See "close finder item
            // hangs the app" root-cause investigation.
            if let backend = backend(for: result) {
                Task.detached(priority: .userInitiated) {
                    backend.activateTab(result)
                }
            }
        case .bookmark, .history:
            if let backend = backend(for: result) {
                Task.detached(priority: .userInitiated) {
                    backend.openURL(result)
                }
            }
        }
    }

    func copyLinkToClipboard(_ result: BrowserSearchResult) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result.url, forType: .string)
        logger.info("copyLinkToClipboard: copied url='\(result.url, privacy: .public)'")
    }

    func remove(_ result: BrowserSearchResult) {
        // All backend mutations route through synchronous `osascript`/sqlite
        // helpers that can stall briefly (and for Finder, occasionally for
        // seconds on first-run TCC prompts or sleeping remote volumes).
        // Dispatch off @MainActor so the UI stays responsive; the snapshot
        // removal + re-fetch below give immediate visual feedback regardless.
        if let backend = backend(for: result) {
            switch result.type {
            case .tab:
                Task.detached(priority: .userInitiated) { backend.closeTab(result) }
                recentlyClosedTabs.append(
                    ClosedTabTombstone(browserName: result.browserName, url: result.url, timestamp: Date())
                )
            case .bookmark:
                Task.detached(priority: .userInitiated) { backend.deleteBookmark(result) }
            case .history:
                Task.detached(priority: .userInitiated) { backend.deleteHistoryItem(result) }
            }
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

    /// Normalizes a URL for duplicate-tab detection:
    /// - Lowercases scheme + host
    /// - Strips ALL trailing slashes (including root "/")
    /// - Drops query string + fragment (session tokens, anchors — same document
    ///   opened with different session params still counts as a duplicate)
    /// Falls back to the raw string for Finder paths or unparseable URLs.
    nonisolated static func normalizeDuplicateURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let comps = URLComponents(string: trimmed),
              let scheme = comps.scheme?.lowercased(),
              !scheme.isEmpty else {
            return trimmed
        }
        let host = (comps.host ?? "").lowercased()
        var path = comps.path
        while path.hasSuffix("/") { path.removeLast() }
        return "\(scheme)://\(host)\(path)"
    }

    private func faviconCacheKey(browserName: String, url: String) -> String {
        // Key by the full page URL, not just the host. Sites like Notion serve a
        // distinct favicon per page (page-specific icon/emoji), stored per
        // `page_url` in the browser's favicon DB. Host-keying would collapse every
        // page of such a site onto one cache slot, so they'd all show whichever
        // favicon resolved first. The backends already resolve per page URL with an
        // origin fallback, so single-favicon sites still share the same image data.
        return "\(browserName)|\(url)"
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
