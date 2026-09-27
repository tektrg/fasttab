import Foundation
import AppKit
import OSLog
import ApplicationServices
import FastTabSync
import CommandBarKit
import IndieSearch

@MainActor
class BrowserTabService: ObservableObject {
    @Published var results: [BrowserSearchResult] = []
    @Published var isLoading: Bool = false
    /// True when the fetched live tabs span more than one window (per browser).
    @Published var hasMultipleWindows: Bool = false
    @Published private(set) var openTabCount: Int = 0
    @Published private(set) var duplicateTabCount: Int = 0
    @Published private(set) var hasFetchedOpenTabCount: Bool = false

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
    /// Last time each tab was seen audible. Drives the sticky-pinned-to-top
    /// grace window in `annotatingPinnedAudibleTabs`. In-memory only — a ~15s
    /// window doesn't need to survive an app restart.
    private var lastAudibleSeenAt: [String: Date] = [:]

    private var fetchTask: Task<Void, Never>?
    private var cacheRefreshTask: Task<Void, Never>?
    private var authoritativeLiveTabsRefreshTask: Task<Void, Never>?

    private var fetchGeneration = 0
    private var lastIssuedQuery: String = ""
    private var lastIssuedFilter: ScopeFilter = ScopeFilter()

    private(set) var cachedBookmarks: [BrowserSearchResult] = []
    private var cachedHistory: [BrowserSearchResult] = []
    private var cacheLastUpdatedAt: Date?
    private var cachedQuickOpenResults: [BrowserSearchResult] = []
    private var cachedQuickOpenSourceAppBundleIdentifier: String?
    private(set) var cachedLiveTabs: [BrowserSearchResult] = []
    private(set) var authoritativeLiveTabSnapshot = AuthoritativeLiveTabSnapshot()
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
    private let historySearchPerBackendLimit = 1000
    // While the user is actively typing, reuse the last live-tab snapshot
    // instead of re-running the multi-browser AppleScript fan-out (100–600ms)
    // on nearly every keystroke. The window slides on each cache hit (see
    // fetchResults), so a continuous typing burst never triggers a rescan; a
    // pause longer than this refetches. Bar-open (empty query) always fetches
    // fresh, so open tabs are current at the start of every session — the only
    // staleness is a tab opened *during* an active burst, which never happens
    // while the user is typing into the bar.
    private let typedQueryLiveTabsReuseWindow: TimeInterval = 5.0

    /// Non-private so the search-alias extension in
    /// `BrowserTabService+SearchAlias.swift` can resolve an alias's owning
    /// browser. Still internal to the module.
    let backends: [any BrowserBackend]

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
    // Throttle for the phantom-twin audit (browser-side existence checks are
    // native-messaging round-trips — cheap, but pointless more than ~1/min).
    private let twinAuditInterval: TimeInterval = 60
    private var lastTwinAuditAt: Date = .distantPast

    init() {
        let enabled = SourceSelectionStore.shared.enabled
        var backends: [any BrowserBackend] = []

        for spec in ChromiumBrowserSpec.all where enabled.contains(spec.source) && Self.isInstalled(bundleIdentifier: spec.bundleIdentifier) {
            let chromium = ChromiumBackend(
                appName: spec.appName,
                bundleIdentifier: spec.bundleIdentifier,
                supportDirectory: spec.supportDirectory
            )
            // Enrichment decorator: serves tabs from the extension when the
            // beta is on and connected; otherwise byte-identical to ChromiumBackend.
            backends.append(ExtensionBackedBackend(inner: chromium, bridge: ExtensionBridge.shared))
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
        logger.info("BrowserTabService init. backends=\(backendAppNames.joined(separator: ","), privacy: .public) frecencyEntries=\(self.frecency.count)")
        startActiveTabPoll()
        observeExtensionTabEvents()
        MyOrderStore.shared.twinAuditor = { [weak self] slots in self?.auditTwinTabs(slots) }
    }

    /// Wires the extension's real-time tab-activation events into frecency
    /// ranking. The 10s front-tab poll only ever sees the front window and
    /// samples on a fixed interval; the extension pushes every activation
    /// the instant it happens, in any window, with its exact timestamp — so
    /// ranking reflects a tab switch immediately instead of catching up on
    /// the next tick. Shares `lastPolledFrontFrecencyKey` with the poll and
    /// with `activate()`'s manual path so the same real switch is never
    /// recorded as two visits, whichever path observes it first.
    private func observeExtensionTabEvents() {
        ExtensionBridge.shared.onTabActivated = { [weak self] appName, tabID, url, at in
            Task { @MainActor in
                guard let self else { return }
                guard ExtensionBetaPreference.isEnabled else {
                    self.logger.info("instant-rank skipped (beta off). app=\(appName, privacy: .public)")
                    return
                }
                let frecencyKey = Frecency.key(browser: appName, profile: nil, url: url)
                if self.lastPolledFrontFrecencyKey[appName] != frecencyKey {
                    self.lastPolledFrontFrecencyKey[appName] = frecencyKey
                    self.recordVisit(frecencyKey: frecencyKey, now: at)
                }
                let urlKey = makeTabURLRecencyKey(browserName: appName, url: url)
                self.lastActiveTimes[urlKey] = at
                if let idx = self.cachedLiveTabs.firstIndex(where: { $0.browserName == appName && $0.tabID == tabID }) ??
                             self.cachedLiveTabs.firstIndex(where: { $0.browserName == appName && $0.url == url }) {
                    self.cachedLiveTabs[idx] = self.cachedLiveTabs[idx].settingTimestamp(at)
                    if let key = self.cachedLiveTabs[idx].tabRecencyKey {
                        self.lastActiveTimes[key] = at
                    }
                }
                if self.lastIssuedQuery.isEmpty {
                    self.rebuildQuickOpenResults()
                }
                self.logger.info("instant-rank applied. app=\(appName, privacy: .public) tabID=\(tabID) url=\(url, privacy: .public)")
            }
        }

        ExtensionBridge.shared.onTabRemoved = { [weak self] appName, tabID, url in
            Task { @MainActor in
                guard let self else { return }
                guard ExtensionBetaPreference.isEnabled else { return }
                let safeURL = url ?? ""
                self.logger.info("extension tabRemoved. app=\(appName, privacy: .public) tabID=\(tabID) url=\(safeURL, privacy: .public)")
                self.removeFirstTab(in: &self.results, browserName: appName, url: safeURL, tabID: tabID)
                self.removeFirstTab(in: &self.cachedQuickOpenResults, browserName: appName, url: safeURL, tabID: tabID)
                self.removeFirstTab(in: &self.cachedLiveTabs, browserName: appName, url: safeURL, tabID: tabID)
                self.openTabCount = self.cachedLiveTabs.count
                self.duplicateTabCount = Self.duplicateTabCount(in: self.cachedLiveTabs)
                MyOrderStore.shared.reconcile(liveTabs: self.cachedLiveTabs)
            }
        }

        ExtensionBridge.shared.onTabUpserted = { [weak self] appName, tabRecord in
            Task { @MainActor in
                guard let self else { return }
                guard ExtensionBetaPreference.isEnabled else { return }
                self.logger.info("extension tabUpserted. app=\(appName, privacy: .public) tabID=\(tabRecord.tabID) pinned=\(tabRecord.isPinned)")
                self.applyTabRecordUpdate(appName: appName, tabRecord: tabRecord)
            }
        }

        ExtensionBridge.shared.onSnapshotReceived = { [weak self] appName, tabs in
            Task { @MainActor in
                guard let self else { return }
                guard ExtensionBetaPreference.isEnabled else { return }
                self.applySnapshotUpdate(appName: appName, extensionTabs: tabs)
            }
        }
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
                        if let idx = self.cachedLiveTabs.firstIndex(where: { $0.browserName == browserName && $0.url == url }) {
                            self.cachedLiveTabs[idx] = self.cachedLiveTabs[idx].settingTimestamp(stamp)
                        }
                        self.cachedQuickOpenResults = []
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

    /// Skips building a Chromium backend for a browser that isn't on this
    /// Mac at all (e.g. Brave enabled as a source but never installed) —
    /// otherwise every poll tick and search fires an AppleScript call that
    /// can only ever fail, for a browser that will never have tabs.
    private static func isInstalled(bundleIdentifier: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
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
        currentFlowSourceAppBundleIdentifier: String?,
        lastAudibleSeenAt: inout [String: Date]
    ) async -> [BrowserSearchResult] {
        if backends.isEmpty { return [] }

        let liveTabs: [BrowserSearchResult]
        if backends.count == 1 {
            liveTabs = backends[0].fetchLiveTabs(
                fetchStart: fetchStart,
                activeTimes: &activeTimes,
                currentFlowSourceAppBundleIdentifier: currentFlowSourceAppBundleIdentifier
            )
        } else {
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

            var collectedTabs: [BrowserSearchResult] = []
            for entry in collected {
                collectedTabs.append(contentsOf: entry.tabs)
                for (key, value) in entry.updates {
                    if let existing = activeTimes[key] {
                        if value > existing { activeTimes[key] = value }
                    } else {
                        activeTimes[key] = value
                    }
                }
            }
            liveTabs = collectedTabs
        }

        return annotatingPinnedAudibleTabs(liveTabs, lastAudibleSeenAt: &lastAudibleSeenAt, now: fetchStart)
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
        let sent = results.filter { $0.type == .sent }.count
        let tabs = results.filter { $0.type == .tab }.count
        let bookmarks = results.filter { $0.type == .bookmark }.count
        let history = results.filter { $0.type == .history }.count
        return "total=\(results.count) sent=\(sent) tabs=\(tabs) bookmarks=\(bookmarks) history=\(history)"
    }

    func prewarmCaches() {
        refreshCachesIfNeeded(force: true)
        refreshAuthoritativeLiveTabsAndPublish()
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

    /// Re-runs whatever the user last searched for. Use this for triggers that
    /// aren't about a new keystroke (a sent-link arriving, a background sync
    /// completing) — calling `fetchResults()` with its empty-query default
    /// would stomp an in-progress typed search back to the unfiltered list.
    func refetchCurrent() {
        fetchResults(matching: lastIssuedQuery, filter: lastIssuedFilter)
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
        let historySearchPerBackendLimit = self.historySearchPerBackendLimit
        let cachedAudibleSeenAt = self.lastAudibleSeenAt
        let slotSnapshot = MyOrderStore.shared.slots

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
            var updatedAudibleSeenAt = cachedAudibleSeenAt
            var produced: [BrowserSearchResult] = []
            var fetchedUnfilteredLiveTabs: [BrowserSearchResult]? = nil

            switch requiredType {
            case .sent:
                let sentLinks = await MainActor.run { SentLinkInbox.shared.asSearchResults() }
                produced = sentLinks.filter { filter.matches($0) }

            case .tab:
                // Live tabs (always fresh — scope-aware fetches don't reuse cache).
                let rawFetchedTabs = await Self.fetchLiveTabsParallel(
                    backends: backends,
                    fetchStart: Date(),
                    baseline: cachedTimes,
                    activeTimes: &updatedTimes,
                    currentFlowSourceAppBundleIdentifier: currentFlowSourceAppBundleIdentifier,
                    lastAudibleSeenAt: &updatedAudibleSeenAt
                )
                if normalizedQuery.isEmpty && pinnedSource == nil && !filter.duplicateOnly && filter.window == nil {
                    fetchedUnfilteredLiveTabs = rawFetchedTabs
                }
                let liveTabs = MyOrderStore.overlayPinStatus(on: rawFetchedTabs, using: slotSnapshot)
                let ghostPinnedTabs = slotSnapshot.compactMap { slot -> BrowserSearchResult? in
                    guard slot.isPinned, slot.state == .ghost else { return nil }
                    return slot.asSearchResult
                }
                let candidateTabs = liveTabs + ghostPinnedTabs
                let allTabs = filter.duplicateOnly ? candidateTabs : deduplicatingSamePages(candidateTabs, frecencyScore: frecencyLookup)
                var sortedTabs = sortBrowserSearchResults(allTabs, frecencyScore: frecencyLookup)

                if filter.duplicateOnly {
                    // Duplicates are scoped per-browser: same URL open in Chrome
                    // and Safari is not surprising and shouldn't be flagged.
                    // URLs must match exactly (see normalizeDuplicateURL).
                    let groupCounts = Self.duplicateGroupCounts(in: sortedTabs)
                    sortedTabs = sortedTabs.filter { groupCounts[$0.browserName + "|" + Self.normalizeDuplicateURL($0.url)] != nil }
                }
                produced = sortedTabs.filter { filter.matches($0) }

            case .bookmark:
                produced = bookmarkSnapshot.filter { filter.matches($0) }

            case .history:
                let collected = await HistorySearchExpansion.search(
                    query: normalizedQuery,
                    backends: backends,
                    perBackendLimit: historySearchPerBackendLimit,
                    since: filter.historySince,
                    before: filter.historyBefore
                )
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
                        currentFlowSourceAppBundleIdentifier: currentFlowSourceAppBundleIdentifier,
                        lastAudibleSeenAt: &updatedAudibleSeenAt
                    )
                    let overlaidLive = MyOrderStore.overlayPinStatus(on: liveTabs, using: slotSnapshot)
                    let ghostPinnedTabs = slotSnapshot.compactMap { slot -> BrowserSearchResult? in
                        guard slot.isPinned, slot.state == .ghost, slot.browserName == pinnedSource else { return nil }
                        return slot.asSearchResult
                    }
                    let candidateTabs = deduplicatingSamePages(overlaidLive + ghostPinnedTabs, frecencyScore: frecencyLookup)
                    // Publish tabs immediately so they're never blocked by the
                    // history DB read below — mirrors the phase-1/phase-2 split
                    // in fetchResultsUnscoped. History merges in at the shared
                    // publish at the end of this task.
                    var earlyTabs = sortBrowserSearchResults(candidateTabs, frecencyScore: frecencyLookup)
                        .filter { filter.matches($0) }
                    if !normalizedQuery.isEmpty {
                        let queryWords = searchWords(in: normalizedQuery)
                        earlyTabs = earlyTabs.filter { $0.matches(words: queryWords) || $0.isPinnedAudibleTab }
                    }
                    await MainActor.run {
                        guard let self, generation == self.fetchGeneration else { return }
                        self.results = self.filteringRecentlyClosed(earlyTabs)
                        self.isLoading = false
                    }
                    let history = await HistorySearchExpansion.search(
                        query: normalizedQuery,
                        backends: backends,
                        perBackendLimit: historySearchPerBackendLimit,
                        since: nil,
                        before: nil
                    )
                    // De-dup: collapse a history row that's the same page as a
                    // currently-open live tab in the same source — avoids the
                    // user seeing the same page twice when they pin to Finder.
                    let merged = deduplicatingSamePages(candidateTabs + history, frecencyScore: frecencyLookup)
                    produced = sortBrowserSearchResults(merged, frecencyScore: frecencyLookup)
                        .filter { filter.matches($0) }
                } else {
                    produced = []
                }
            }

            // Apply free-text filter (history is already query-filtered at SQL).
            // A pinned-audible tab always survives the filter, even if it
            // doesn't match what's typed — it stays pinned regardless of query.
            if !normalizedQuery.isEmpty, requiredType != .history {
                let queryWords = searchWords(in: normalizedQuery)
                produced = produced.filter { $0.matches(words: queryWords) || $0.isPinnedAudibleTab }
            }

            await MainActor.run {
                guard let self, generation == self.fetchGeneration else { return }
                self.lastActiveTimes = updatedTimes
                self.lastAudibleSeenAt = updatedAudibleSeenAt
                self.persistActiveTimes()
                // Refresh live-tabs cache if we just fetched fresh, unfiltered ones.
                if let rawLiveTabs = fetchedUnfilteredLiveTabs {
                    let rawLive = self.filteringRecentlyClosed(rawLiveTabs.filter { $0.type == .tab && !$0.isGhost })
                    MyOrderStore.shared.reconcile(liveTabs: rawLive)
                    let freshLive = sortBrowserSearchResults(MyOrderStore.shared.overlayPinStatus(on: rawLive), frecencyScore: frecencyLookup)
                    self.cachedLiveTabs = freshLive
                    self.lastLiveTabsRefreshAt = Date()
                    self.hasMultipleWindows = Self.computeHasMultipleWindows(freshLive)
                    self.openTabCount = freshLive.count
                    self.duplicateTabCount = Self.duplicateTabCount(in: freshLive)
                    self.hasFetchedOpenTabCount = true
                }
                let overlaidResults = MyOrderStore.shared.overlayPinStatus(on: self.filteringRecentlyClosed(produced))
                self.results = sortBrowserSearchResults(overlaidResults, frecencyScore: frecencyLookup)
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
            results = filteringRecentlyClosed(cachedQuickOpenResults)
        }
        isLoading = true

        lastIssuedQuery = normalizedQuery

        let cachedTimes = self.lastActiveTimes
        let backends = self.backends
        let bookmarkSnapshot = self.cachedBookmarks
        let historySnapshot = self.cachedHistory
        let cachedLiveTabsSnapshot = self.cachedLiveTabs
        let lastLiveTabsRefreshAt = self.lastLiveTabsRefreshAt
        let typedQueryLiveTabsReuseWindow = self.typedQueryLiveTabsReuseWindow
        let frecencyLookup = makeFrecencyScoreLookup()
        let historySearchPerBackendLimit = self.historySearchPerBackendLimit
        let cachedAudibleSeenAt = self.lastAudibleSeenAt
        let slotSnapshot = MyOrderStore.shared.slots

        logger.info("fetchResults start. generation=\(generation) query='\(normalizedQuery, privacy: .public)' bookmarkSnapshot=\(bookmarkSnapshot.count) historySnapshot=\(historySnapshot.count)")

        fetchTask = Task.detached(priority: .userInitiated) { [weak self] in
            var updatedTimes = cachedTimes
            var updatedAudibleSeenAt = cachedAudibleSeenAt
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
                    currentFlowSourceAppBundleIdentifier: currentFlowSourceAppBundleIdentifier,
                    lastAudibleSeenAt: &updatedAudibleSeenAt
                )

                if !cachedLiveTabsSnapshot.isEmpty {
                    let knownURLs = Set(cachedLiveTabsSnapshot.map(\.url))
                    liveTabs = liveTabs.map { tab in
                        if tab.timestamp == Date(timeIntervalSince1970: 0) && !knownURLs.contains(tab.url) {
                            let newTime = fetchStart.addingTimeInterval(-2)
                            if let urlKey = tab.tabURLRecencyKey {
                                updatedTimes[urlKey] = newTime
                            }
                            return tab.settingTimestamp(newTime)
                        }
                        return tab
                    }
                }
            }

            liveTabs = MyOrderStore.overlayPinStatus(on: liveTabs, using: slotSnapshot)

            guard !Task.isCancelled else {
                await MainActor.run {
                    guard let self, generation == self.fetchGeneration else { return }
                    self.isLoading = false
                }
                return
            }

            // Empty query (quick-open) must rank by raw recency so the
            // tab you *just* used is always at the top — a hard UX guarantee
            // that frecency would violate (a daily-driver gmail tab would
            // outrank the tab you alt-tabbed to 5 seconds ago). Typed-query
            // paths below re-sort with frecency.
            let sortedLiveTabs: [BrowserSearchResult]
            let quickOpenTabs: [BrowserSearchResult]?
            if normalizedQuery.isEmpty {
                quickOpenTabs = allQuickOpenTabs(from: liveTabs)
                sortedLiveTabs = liveTabs
            } else {
                sortedLiveTabs = sortBrowserSearchResults(liveTabs, frecencyScore: frecencyLookup)
                quickOpenTabs = nil
            }
            let recencyTopPreview = (quickOpenTabs ?? sortedLiveTabs).prefix(10).map { r -> String in
                "[win=\(r.windowIndex ?? -1) tab=\(r.tabIndex ?? -1) ts=\(Int(r.timestamp.timeIntervalSince1970)) '\(r.title.prefix(40))']"
            }.joined(separator: " ")
            Logger(subsystem: "com.trungluong.FastTab", category: "BrowserTabService").info("recency-sort post-sort top10. generation=\(generation) usedCachedLiveTabs=\(usedCachedLiveTabs, privacy: .public) liveTabsCount=\(sortedLiveTabs.count) top='\(recencyTopPreview, privacy: .public)'")

            if normalizedQuery.isEmpty {
                await MainActor.run {
                    guard let self, generation == self.fetchGeneration else { return }
                    let rawLiveTabs = self.filteringRecentlyClosed(sortedLiveTabs)
                    MyOrderStore.shared.reconcile(liveTabs: rawLiveTabs)
                    let filteredLiveTabs = MyOrderStore.shared.overlayPinStatus(on: rawLiveTabs)
                    let prioritizedTabs = allQuickOpenTabs(from: filteredLiveTabs)
                    let filteredPrioritized = self.filteringRecentlyClosed(prioritizedTabs)
                    let dedupedPrioritized = deduplicatingSamePages(filteredPrioritized, frecencyScore: { _ in 0 })
                    let combinedQuickOpen = sortQuickOpenResults(dedupedPrioritized)

                    self.lastActiveTimes = updatedTimes
                    self.lastAudibleSeenAt = updatedAudibleSeenAt
                    self.persistActiveTimes()
                    self.results = combinedQuickOpen
                    self.cachedQuickOpenResults = combinedQuickOpen
                    self.cachedQuickOpenSourceAppBundleIdentifier = currentFlowSourceAppBundleIdentifier
                    self.cachedLiveTabs = filteredLiveTabs
                    self.lastLiveTabsRefreshAt = Date()
                    self.hasMultipleWindows = Self.computeHasMultipleWindows(filteredLiveTabs)
                    self.openTabCount = filteredLiveTabs.count
                    self.duplicateTabCount = Self.duplicateTabCount(in: filteredLiveTabs)
                    self.hasFetchedOpenTabCount = true
                    self.isLoading = false
                    self.logger.info("fetchResults applied (empty-query fast path). generation=\(generation) quickOpenTabs=\(filteredPrioritized.count) liveTabs={\(Self.typeBreakdown(filteredLiveTabs), privacy: .public)}")
                    SyncService.shared.updateLiveTabs(filteredLiveTabs)
                    self.refreshCachesIfNeeded(force: false)
                }
                return
            }

            // Fold the typed query once and reuse it across every candidate
            // below — sent links, live tabs, and bookmarks can together number
            // in the hundreds, and re-folding the same query per candidate
            // (Unicode case/accent/width folding) was measurable per keystroke.
            let queryWords = searchWords(in: normalizedQuery)

            let sentMatches = await MainActor.run {
                SentLinkInbox.shared.asSearchResults().filter { $0.matches(words: queryWords) }
            }

            let ghostPinnedTabs = slotSnapshot.compactMap { slot -> BrowserSearchResult? in
                guard slot.isPinned, slot.state == .ghost else { return nil }
                return slot.asSearchResult
            }
            let ghostPinnedMatches = ghostPinnedTabs.filter { $0.matches(words: queryWords) }

            // A pinned-audible tab always survives the filter, even if it
            // doesn't match what's typed — it stays pinned regardless of query.
            let tabMatches = sortedLiveTabs.filter { $0.matches(words: queryWords) || $0.isPinnedAudibleTab }
            let bookmarkMatches = bookmarkSnapshot.filter { $0.matches(words: queryWords) }

            // Phase 1: publish sent links + tabs + ghost pinned tabs + bookmarks immediately so UI isn't blocked by history DB I/O
            let phase1Deduped = deduplicatingSamePages(sentMatches + tabMatches + ghostPinnedMatches + bookmarkMatches, frecencyScore: frecencyLookup)
            let phase1Results = sortBrowserSearchResults(phase1Deduped, frecencyScore: frecencyLookup)
            await MainActor.run {
                guard let self, generation == self.fetchGeneration else { return }
                let rawLiveTabs = self.filteringRecentlyClosed(sortedLiveTabs)
                if !usedCachedLiveTabs {
                    MyOrderStore.shared.reconcile(liveTabs: rawLiveTabs)
                }
                let filteredLiveTabs = MyOrderStore.shared.overlayPinStatus(on: rawLiveTabs)
                let filteredPhase1 = sortBrowserSearchResults(
                    MyOrderStore.shared.overlayPinStatus(on: self.filteringRecentlyClosed(phase1Results)),
                    frecencyScore: frecencyLookup
                )
                self.lastActiveTimes = updatedTimes
                self.lastAudibleSeenAt = updatedAudibleSeenAt
                self.persistActiveTimes()
                if !usedCachedLiveTabs {
                    self.cachedLiveTabs = filteredLiveTabs
                    self.lastLiveTabsRefreshAt = Date()
                    self.hasMultipleWindows = Self.computeHasMultipleWindows(filteredLiveTabs)
                    self.openTabCount = filteredLiveTabs.count
                    self.duplicateTabCount = Self.duplicateTabCount(in: filteredLiveTabs)
                    self.hasFetchedOpenTabCount = true
                    SyncService.shared.updateLiveTabs(filteredLiveTabs)
                } else {
                    // Slide the reuse window: the user is mid typing-burst, so
                    // keep trusting the cached snapshot instead of rescanning.
                    self.lastLiveTabsRefreshAt = Date()
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

            // Phase 2: run history search per backend concurrently, widening
            // from recent to older history when the history result set is sparse.
            let historyMatches = await HistorySearchExpansion.search(
                query: normalizedQuery,
                backends: backends,
                perBackendLimit: historySearchPerBackendLimit,
                since: nil,
                before: nil
            )

            let mergedDeduped = deduplicatingSamePages(sentMatches + tabMatches + ghostPinnedMatches + bookmarkMatches + historyMatches, frecencyScore: frecencyLookup)
            let mergedResults = sortBrowserSearchResults(mergedDeduped, frecencyScore: frecencyLookup)

            await MainActor.run {
                guard let self, generation == self.fetchGeneration else { return }
                let filteredFinal = sortBrowserSearchResults(
                    MyOrderStore.shared.overlayPinStatus(on: self.filteringRecentlyClosed(mergedResults)),
                    frecencyScore: frecencyLookup
                )
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
        case .sent:
            if let commandID = result.bookmarkID {
                let completedCmd = SentLinkInbox.shared.markOpened(commandID: commandID)
                if let completedCmd {
                    SyncService.shared.pushCommandResult(completedCmd)
                }
            }
            openSentLink(result)
        case .tab:
            let now = Date()
            if let key = result.tabRecencyKey {
                lastActiveTimes[key] = now
            }
            if let urlKey = result.tabURLRecencyKey {
                lastActiveTimes[urlKey] = now
            }
            persistActiveTimes()
            logger.info("recency-sort activate persisted. key='\(result.tabRecencyKey ?? "", privacy: .public)' epoch=\(now.timeIntervalSince1970) totalKeys=\(self.lastActiveTimes.count) title='\(result.title, privacy: .public)'")
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
            if result.isGhost {
                MyOrderStore.shared.reopenSlot(matching: result)
            } else if let backend = backend(for: result) {
                Task.detached(priority: .userInitiated) {
                    backend.activateTab(result)
                }
            }
        case .bookmark, .history:
            openViaWebAppRoutingOrNormally(result)
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
        switch result.type {
        case .sent:
            if let commandID = result.bookmarkID {
                let dismissedCmd = SentLinkInbox.shared.dismiss(commandID: commandID)
                if let dismissedCmd {
                    SyncService.shared.pushCommandResult(dismissedCmd)
                }
            }
        case .tab:
            if result.isGhost {
                MyOrderStore.shared.deleteGhostSlot(matching: result)
            } else if let backend = backend(for: result) {
                Task.detached(priority: .userInitiated) { backend.closeTab(result) }
                recentlyClosedTabs.append(
                    ClosedTabTombstone(browserName: result.browserName, url: result.url, timestamp: Date())
                )
            }
        case .bookmark:
            if let backend = backend(for: result) {
                Task.detached(priority: .userInitiated) { backend.deleteBookmark(result) }
            }
        case .history:
            if let backend = backend(for: result) {
                Task.detached(priority: .userInitiated) { backend.deleteHistoryItem(result) }
            }
        }

        removeResultFromLocalSnapshots(matching: result)
        if result.type == .tab {
            MyOrderStore.shared.reconcile(liveTabs: cachedLiveTabs)
        }
        fetchResults(matching: lastIssuedQuery, filter: lastIssuedFilter)
    }

    /// Asynchronously deletes a bookmark via the appropriate backend/extension,
    /// returning whether the deletion succeeded. On success, updates local snapshots
    /// and tree store immediately so the UI reflects the deletion.
    @discardableResult
    func deleteBookmarkAsync(_ result: BrowserSearchResult) async -> Bool {
        guard result.type == .bookmark else { return false }
        guard let backend = backend(for: result) else {
            logger.warning("deleteBookmarkAsync: no backend found for browser=\(result.browserName, privacy: .public)")
            return false
        }
        let success = await Task.detached(priority: .userInitiated) {
            backend.deleteBookmark(result)
        }.value

        if success {
            removeResultFromLocalSnapshots(matching: result, updateTreeStore: false)
            fetchResults(matching: lastIssuedQuery, filter: lastIssuedFilter)
        }
        return success
    }

    /// Mutes (or unmutes) a tab from the "Playing now" strip. Dispatches the
    /// extension command in the background and updates local snapshots
    /// immediately so the row reflects the new state (and, once muted, drops
    /// out of the audible strip) without waiting on the next poll.
    func toggleMute(_ result: BrowserSearchResult) {
        guard result.type == .tab else { return }
        let newMuted = !result.isMuted
        logger.info("toggleMute tapped. title='\(result.title, privacy: .public)' browser=\(result.browserName, privacy: .public) tabID=\(result.tabID ?? -1) newMuted=\(newMuted)")
        if let backend = backend(for: result) {
            Task.detached(priority: .userInitiated) { backend.toggleMuteTab(result, muted: newMuted) }
        } else {
            logger.error("toggleMute: no backend found for browser=\(result.browserName, privacy: .public)")
        }
        if newMuted, let key = result.tabRecencyKey {
            // Otherwise the sticky-audible grace window (annotatingPinnedAudibleTabs)
            // would re-pin this tab on the next fetch, since it was genuinely
            // heard within the last 15s — even though the user just silenced
            // it on purpose.
            lastAudibleSeenAt.removeValue(forKey: key)
        }
        applyMutedOptimistically(newMuted, to: result)
    }

    /// Pins (or unpins) a tab in the browser and updates local snapshots immediately.
    func togglePin(_ result: BrowserSearchResult, pinned: Bool? = nil) {
        guard result.type == .tab else { return }
        if result.isGhost {
            MyOrderStore.shared.deleteGhostSlot(matching: result)
            removeResultFromLocalSnapshots(matching: result)
            return
        }
        let targetPinned = pinned ?? !result.isPinned
        logger.info("togglePin tapped. title='\(result.title, privacy: .public)' browser=\(result.browserName, privacy: .public) tabID=\(result.tabID ?? -1) targetPinned=\(targetPinned)")
        if let backend = backend(for: result) {
            Task.detached(priority: .userInitiated) { backend.togglePinTab(result, pinned: targetPinned) }
        } else {
            logger.error("togglePin: no backend found for browser=\(result.browserName, privacy: .public)")
        }
        applyPinnedOptimistically(targetPinned, to: result)
    }

    private func removeResultFromLocalSnapshots(matching result: BrowserSearchResult, updateTreeStore: Bool = true) {
        let resultID = result.id
        switch result.type {
        case .sent:
            results.removeAll { $0.id == resultID }
            cachedQuickOpenResults.removeAll { $0.id == resultID }
        case .tab:
            // Indices can shift after a close, so match tabs by (browser, url) with
            // "consume one" semantics — only the first matching tab in each list is removed,
            // preserving duplicates that may legitimately exist in other windows.
            removeFirstTab(in: &results, browserName: result.browserName, url: result.url, tabID: result.tabID)
            removeFirstTab(in: &cachedQuickOpenResults, browserName: result.browserName, url: result.url, tabID: result.tabID)
            removeFirstTab(in: &cachedLiveTabs, browserName: result.browserName, url: result.url, tabID: result.tabID)
        case .bookmark, .history:
            results.removeAll { $0.id == resultID }
            cachedQuickOpenResults.removeAll { $0.id == resultID }
            cachedBookmarks.removeAll { $0.id == resultID }
            cachedHistory.removeAll { $0.id == resultID }
            if updateTreeStore, result.type == .bookmark, let bmID = result.bookmarkID {
                BookmarkTreeStore.shared.removeBookmark(id: bmID)
            }
        }
        openTabCount = cachedLiveTabs.count
        duplicateTabCount = Self.duplicateTabCount(in: cachedLiveTabs)
    }

    /// Phantom-twin audit — the "check the match" half of slot↔browser-tab
    /// reconciliation. When two live records claim the same page under
    /// different tab IDs (stale pre-replacement ID kept next to the live one),
    /// slot-level matching cannot tell them apart: both carry the same URL, so
    /// a URL check passes for both. The only authority is the browser itself,
    /// so the older twin(s) get a read-only `chrome.tabs.get` existence check.
    /// `.missing` means the browser denied the ID (its record was already
    /// purged from every connection by the shared command-result path) — the
    /// stale rows are dropped and slots re-reconcile ("close"). `.exists`
    /// means a legit same-URL duplicate (two SPA views) — kept. `.unknown`
    /// (timeout, older extension) is inconclusive — kept, retried next window.
    /// Runs off-main (the check blocks on a native-messaging round-trip) and
    /// at most once per `twinAuditInterval`.
    private func auditTwinTabs(_ slots: [OrderedTabSlot]) {
        guard ExtensionBetaPreference.isEnabled else { return }
        let now = Date()
        guard now.timeIntervalSince(lastTwinAuditAt) > twinAuditInterval else { return }
        let suspects = MyOrderReconciler.findTwinSuspects(in: slots)
        guard !suspects.isEmpty else { return }
        lastTwinAuditAt = now
        logger.info("twin audit start. groups=\(suspects.count)")
        Task.detached(priority: .utility) { [weak self] in
            var purged: [(browserName: String, tabID: Int)] = []
            for suspect in suspects {
                // Newest ID is presumed live; verify the older twins.
                for tabID in suspect.tabIDs.dropLast() {
                    let verdict = ExtensionBridge.shared.verifyTabExists(
                        appName: suspect.browserName, tabID: tabID, timeout: 2.0
                    )
                    if verdict == .missing {
                        purged.append((suspect.browserName, tabID))
                    }
                }
            }
            guard !purged.isEmpty else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                for victim in purged {
                    self.logger.info("twin audit purge. app=\(victim.browserName, privacy: .public) tabID=\(victim.tabID)")
                    self.removeFirstTab(in: &self.results, browserName: victim.browserName, url: "", tabID: victim.tabID)
                    self.removeFirstTab(in: &self.cachedQuickOpenResults, browserName: victim.browserName, url: "", tabID: victim.tabID)
                    self.removeFirstTab(in: &self.cachedLiveTabs, browserName: victim.browserName, url: "", tabID: victim.tabID)
                }
                self.openTabCount = self.cachedLiveTabs.count
                self.duplicateTabCount = Self.duplicateTabCount(in: self.cachedLiveTabs)
                MyOrderStore.shared.reconcile(liveTabs: self.cachedLiveTabs)
                if self.lastIssuedQuery.isEmpty {
                    self.rebuildQuickOpenResults()
                }
            }
        }
    }

    private func removeFirstTab(in list: inout [BrowserSearchResult], browserName: String, url: String, tabID: Int? = nil) {        if let tabID, let idx = list.firstIndex(where: { $0.type == .tab && $0.browserName == browserName && $0.tabID == tabID }) {
            list.remove(at: idx)
            return
        }
        if !url.isEmpty, let idx = list.firstIndex(where: { $0.type == .tab && $0.browserName == browserName && $0.url == url }) {
            list.remove(at: idx)
        }
    }

    /// Called by `SyncService` when a tab was closed remotely (e.g. from iOS).
    /// Records a tombstone so subsequent poll cycles don't resurrect the tab,
    /// removes the tab from in-memory snapshots, and notifies CloudKit of the updated tab list.
    @discardableResult
    func recordClosedTabFromRemote(browserName: String, url: String, tabID: Int? = nil) -> Bool {
        recentlyClosedTabs.append(
            ClosedTabTombstone(browserName: browserName, url: url, timestamp: Date())
        )
        removeFirstTab(in: &results, browserName: browserName, url: url, tabID: tabID)
        removeFirstTab(in: &cachedQuickOpenResults, browserName: browserName, url: url, tabID: tabID)
        removeFirstTab(in: &cachedLiveTabs, browserName: browserName, url: url, tabID: tabID)
        openTabCount = cachedLiveTabs.count
        duplicateTabCount = Self.duplicateTabCount(in: cachedLiveTabs)
        refreshAuthoritativeLiveTabsAndPublish()
        return true
    }

    func refreshAuthoritativeLiveTabsAndPublish() {
        authoritativeLiveTabsRefreshTask?.cancel()
        // Supersede any still-pending debounced UI publish: its snapshot is
        // older than the one we are about to fetch, and publishing it after
        // us would re-add a tab that has since closed.
        SyncService.shared.cancelPendingLiveTabsPublish()
        let backends = self.backends
        let cachedTimes = self.lastActiveTimes
        let cachedAudibleSeenAt = self.lastAudibleSeenAt
        let sourceAppBundleIdentifier = self.currentFlowSourceAppBundleIdentifier

        authoritativeLiveTabsRefreshTask = Task.detached(priority: .utility) { [weak self] in
            var updatedTimes = cachedTimes
            var updatedAudibleSeenAt = cachedAudibleSeenAt
            let fetchedTabs = await Self.fetchLiveTabsParallel(
                backends: backends,
                fetchStart: Date(),
                baseline: cachedTimes,
                activeTimes: &updatedTimes,
                currentFlowSourceAppBundleIdentifier: sourceAppBundleIdentifier,
                lastAudibleSeenAt: &updatedAudibleSeenAt
            )
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard let self else { return }
                let rawAuthoritativeTabs = self.filteringRecentlyClosed(fetchedTabs)
                MyOrderStore.shared.reconcile(liveTabs: rawAuthoritativeTabs)
                let authoritativeTabs = MyOrderStore.shared.overlayPinStatus(on: rawAuthoritativeTabs)
                self.cachedLiveTabs = authoritativeTabs
                self.openTabCount = authoritativeTabs.count
                self.duplicateTabCount = Self.duplicateTabCount(in: authoritativeTabs)
                self.hasFetchedOpenTabCount = true
                self.hasMultipleWindows = Self.computeHasMultipleWindows(authoritativeTabs)
                self.lastLiveTabsRefreshAt = Date()

                let prioritizedTabs = allQuickOpenTabs(from: authoritativeTabs)
                let dedupedPrioritized = deduplicatingSamePages(prioritizedTabs, frecencyScore: { _ in 0 })
                let combined = sortQuickOpenResults(dedupedPrioritized)

                self.cachedQuickOpenResults = combined
                self.cachedQuickOpenSourceAppBundleIdentifier = sourceAppBundleIdentifier
                if self.lastIssuedQuery.isEmpty {
                    self.results = combined
                } else {
                    let frecencyLookup = self.makeFrecencyScoreLookup()
                    self.results = sortBrowserSearchResults(MyOrderStore.shared.overlayPinStatus(on: self.results), frecencyScore: frecencyLookup)
                }

                self.authoritativeLiveTabSnapshot.applyAllBackends(authoritativeTabs)
                self.lastActiveTimes = updatedTimes
                self.lastAudibleSeenAt = updatedAudibleSeenAt
                SyncService.shared.requestLiveTabsPublish(authoritativeTabs)
                TabActivityRecorder.shared.observe(authoritativeTabs)
                self.logger.info("Authoritative all-browser tab sync published. tabCount=\(authoritativeTabs.count)")
            }
        }
    }

    #if DEBUG
    func setTestLiveTabsState(tabs: [BrowserSearchResult], isHydrated: Bool = true) {
        self.results = tabs
        self.cachedQuickOpenResults = tabs
        self.cachedLiveTabs = tabs
        self.openTabCount = tabs.count
        self.hasFetchedOpenTabCount = isHydrated
    }
    #endif

    private func applyMutedOptimistically(_ muted: Bool, to result: BrowserSearchResult) {
        applyMuted(muted, to: result.id, in: &results)
        applyMuted(muted, to: result.id, in: &cachedQuickOpenResults)
        applyMuted(muted, to: result.id, in: &cachedLiveTabs)
    }

    private func applyMuted(_ muted: Bool, to resultID: String, in list: inout [BrowserSearchResult]) {
        guard let idx = list.firstIndex(where: { $0.id == resultID }) else { return }
        list[idx] = list[idx].settingMuted(muted)
    }

    private func applyPinnedOptimistically(_ pinned: Bool, to result: BrowserSearchResult) {
        applyPinned(pinned, to: result.id, tabID: result.tabID, browserName: result.browserName, in: &results)
        applyPinned(pinned, to: result.id, tabID: result.tabID, browserName: result.browserName, in: &cachedQuickOpenResults)
        applyPinned(pinned, to: result.id, tabID: result.tabID, browserName: result.browserName, in: &cachedLiveTabs)
        MyOrderStore.shared.setSlotPinned(
            browserName: result.browserName,
            url: result.url,
            tabID: result.tabID,
            isPinned: pinned
        )
        if lastIssuedQuery.isEmpty {
            results = sortQuickOpenResults(results)
        } else {
            let frecencyLookup = makeFrecencyScoreLookup()
            results = sortBrowserSearchResults(results, frecencyScore: frecencyLookup)
        }
        cachedQuickOpenResults = sortQuickOpenResults(cachedQuickOpenResults)
    }

    private func applyPinned(
        _ pinned: Bool,
        to resultID: String,
        fallbackID: String? = nil,
        tabID: Int? = nil,
        browserName: String? = nil,
        in list: inout [BrowserSearchResult]
    ) {
        if let tabID, let browserName, let idx = list.firstIndex(where: { $0.type == .tab && $0.browserName == browserName && $0.tabID == tabID }) {
            list[idx] = list[idx].settingPinned(pinned)
            return
        }
        guard let idx = list.firstIndex(where: { $0.id == resultID || (fallbackID != nil && $0.id == fallbackID) }) else { return }
        list[idx] = list[idx].settingPinned(pinned)
    }

    private func applyTabRecordUpdate(appName: String, tabRecord: ExtensionTabRecord) {
        let isAudibleToUser = tabRecord.isAudible && !tabRecord.isMuted
        if let idx = cachedLiveTabs.firstIndex(where: { $0.browserName == appName && $0.tabID == tabRecord.tabID }) {
            let existing = cachedLiveTabs[idx]
            let timestamp: Date
            if tabRecord.isActive {
                timestamp = tabRecord.lastAccessed ?? Date()
            } else if let lastAccessed = tabRecord.lastAccessed {
                timestamp = max(lastAccessed, existing.timestamp)
            } else {
                timestamp = existing.timestamp
            }
            if timestamp > Date(timeIntervalSince1970: 0) {
                let key = makeTabRecencyKey(browserName: appName, windowIndex: tabRecord.windowIndex, tabIndex: tabRecord.tabIndex, url: tabRecord.url)
                let urlKey = makeTabURLRecencyKey(browserName: appName, url: tabRecord.url)
                lastActiveTimes[key] = timestamp
                lastActiveTimes[urlKey] = timestamp
            }
            let updated = BrowserSearchResult(
                title: tabRecord.title,
                url: tabRecord.url,
                browserName: appName,
                type: .tab,
                timestamp: timestamp,
                windowIndex: tabRecord.windowIndex,
                tabIndex: tabRecord.tabIndex,
                windowName: tabRecord.windowName,
                profileName: existing.profileName,
                isCurrentFlowActiveTab: tabRecord.isActive,
                hasMediaIndicator: isAudibleToUser,
                tabID: tabRecord.tabID,
                isAudible: tabRecord.isAudible,
                isMuted: tabRecord.isMuted,
                isPinned: tabRecord.isPinned,
                isDiscarded: tabRecord.isDiscarded,
                tabGroupTitle: tabRecord.groupTitle,
                isPinnedAudibleTab: isAudibleToUser
            )
            cachedLiveTabs[idx] = updated
            if tabRecord.isPinned {
                MyOrderStore.shared.setSlotPinned(
                    browserName: appName,
                    url: tabRecord.url,
                    tabID: tabRecord.tabID,
                    isPinned: true
                )
            }
            MyOrderStore.shared.reconcile(liveTabs: cachedLiveTabs)
            let effectivePinned = tabRecord.isPinned || MyOrderStore.shared.isSlotPinned(browserName: appName, url: tabRecord.url, tabID: tabRecord.tabID)
            cachedLiveTabs[idx] = cachedLiveTabs[idx].settingPinned(effectivePinned)
            if lastIssuedQuery.isEmpty {
                rebuildQuickOpenResults()
            } else {
                applyPinned(effectivePinned, to: existing.id, fallbackID: updated.id, tabID: tabRecord.tabID, browserName: appName, in: &results)
                applyPinned(effectivePinned, to: existing.id, fallbackID: updated.id, tabID: tabRecord.tabID, browserName: appName, in: &cachedQuickOpenResults)
                let frecencyLookup = makeFrecencyScoreLookup()
                results = sortBrowserSearchResults(results, frecencyScore: frecencyLookup)
                cachedQuickOpenResults = sortQuickOpenResults(cachedQuickOpenResults)
            }
        } else {
            // If this is a replaced/woken tab ID for an existing tab in the same window,
            // remove the stale predecessor so it doesn't linger as a duplicate.
            let canonical = MyOrderReconciler.canonicalURL(tabRecord.url)
            cachedLiveTabs.removeAll {
                $0.browserName == appName &&
                $0.tabID != tabRecord.tabID &&
                ($0.windowIndex ?? 1) == tabRecord.windowIndex &&
                MyOrderReconciler.canonicalURL($0.url) == canonical
            }

            let timestamp = tabRecord.lastAccessed ?? Date()
            if timestamp > Date(timeIntervalSince1970: 0) {
                let key = makeTabRecencyKey(browserName: appName, windowIndex: tabRecord.windowIndex, tabIndex: tabRecord.tabIndex, url: tabRecord.url)
                let urlKey = makeTabURLRecencyKey(browserName: appName, url: tabRecord.url)
                lastActiveTimes[key] = timestamp
                lastActiveTimes[urlKey] = timestamp
            }

            let newTab = BrowserSearchResult(
                title: tabRecord.title,
                url: tabRecord.url,
                browserName: appName,
                type: .tab,
                timestamp: timestamp,
                windowIndex: tabRecord.windowIndex,
                tabIndex: tabRecord.tabIndex,
                windowName: tabRecord.windowName,
                profileName: nil,
                isCurrentFlowActiveTab: tabRecord.isActive,
                hasMediaIndicator: isAudibleToUser,
                tabID: tabRecord.tabID,
                isAudible: tabRecord.isAudible,
                isMuted: tabRecord.isMuted,
                isPinned: tabRecord.isPinned,
                isDiscarded: tabRecord.isDiscarded,
                tabGroupTitle: tabRecord.groupTitle,
                isPinnedAudibleTab: isAudibleToUser
            )
            cachedLiveTabs.append(newTab)
            openTabCount = cachedLiveTabs.count
            duplicateTabCount = Self.duplicateTabCount(in: cachedLiveTabs)
            MyOrderStore.shared.reconcile(liveTabs: cachedLiveTabs)
            let effectivePinned = tabRecord.isPinned || MyOrderStore.shared.isSlotPinned(browserName: appName, url: tabRecord.url, tabID: tabRecord.tabID)
            if let lastIdx = cachedLiveTabs.indices.last {
                cachedLiveTabs[lastIdx] = cachedLiveTabs[lastIdx].settingPinned(effectivePinned)
            }
            if effectivePinned {
                MyOrderStore.shared.setSlotPinned(
                    browserName: appName,
                    url: tabRecord.url,
                    tabID: tabRecord.tabID,
                    isPinned: true
                )
            }
            if lastIssuedQuery.isEmpty {
                rebuildQuickOpenResults()
            }
        }
    }

    private func rebuildQuickOpenResults() {
        let filteredLiveTabs = MyOrderStore.shared.overlayPinStatus(on: cachedLiveTabs)
        let prioritizedTabs = allQuickOpenTabs(from: filteredLiveTabs)
        let filteredPrioritized = filteringRecentlyClosed(prioritizedTabs)
        let dedupedPrioritized = deduplicatingSamePages(filteredPrioritized, frecencyScore: { _ in 0 })
        let combinedQuickOpen = sortQuickOpenResults(dedupedPrioritized)
        results = combinedQuickOpen
        cachedQuickOpenResults = combinedQuickOpen
    }

    private func applySnapshotUpdate(appName: String, extensionTabs: [ExtensionTabRecord]) {
        guard !extensionTabs.isEmpty else { return }
        logger.info("extension snapshot received. app=\(appName, privacy: .public) tabs=\(extensionTabs.count)")

        let now = Date()
        let freshTabs = extensionTabs.map { tabRecord -> BrowserSearchResult in
            let isAudibleToUser = tabRecord.isAudible && !tabRecord.isMuted
            let key = makeTabRecencyKey(browserName: appName, windowIndex: tabRecord.windowIndex, tabIndex: tabRecord.tabIndex, url: tabRecord.url)
            let urlKey = makeTabURLRecencyKey(browserName: appName, url: tabRecord.url)
            let storedTime = lastActiveTimes[key] ?? lastActiveTimes[urlKey]
            let timestamp: Date
            if tabRecord.isActive && tabRecord.windowIndex == 1 {
                timestamp = tabRecord.lastAccessed ?? now
            } else if let lastAccessed = tabRecord.lastAccessed {
                if let stored = storedTime {
                    timestamp = max(lastAccessed, stored)
                } else {
                    timestamp = lastAccessed
                }
            } else if let stored = storedTime {
                timestamp = stored
            } else {
                timestamp = Date(timeIntervalSince1970: 0)
            }
            if timestamp > Date(timeIntervalSince1970: 0) {
                lastActiveTimes[key] = timestamp
                lastActiveTimes[urlKey] = timestamp
            }
            return BrowserSearchResult(
                title: tabRecord.title,
                url: tabRecord.url,
                browserName: appName,
                type: .tab,
                timestamp: timestamp,
                windowIndex: tabRecord.windowIndex,
                tabIndex: tabRecord.tabIndex,
                windowName: tabRecord.windowName,
                profileName: nil,
                isCurrentFlowActiveTab: tabRecord.isActive,
                hasMediaIndicator: isAudibleToUser,
                tabID: tabRecord.tabID,
                isAudible: tabRecord.isAudible,
                isMuted: tabRecord.isMuted,
                isPinned: tabRecord.isPinned,
                isDiscarded: tabRecord.isDiscarded,
                tabGroupTitle: tabRecord.groupTitle,
                isPinnedAudibleTab: isAudibleToUser
            )
        }

        var updatedTabs = cachedLiveTabs.filter { $0.browserName != appName }
        updatedTabs.append(contentsOf: freshTabs)

        cachedLiveTabs = updatedTabs
        openTabCount = cachedLiveTabs.count
        duplicateTabCount = Self.duplicateTabCount(in: cachedLiveTabs)
        MyOrderStore.shared.reconcile(liveTabs: cachedLiveTabs)

        if lastIssuedQuery.isEmpty {
            rebuildQuickOpenResults()
        }
    }


    private func pruneClosedTabTombstones() {
        let cutoff = Date().addingTimeInterval(-closedTabTombstoneTTL)
        recentlyClosedTabs.removeAll { $0.timestamp < cutoff }
    }

    /// Cancels any recently-closed suppression entry for a given browser and URL.
    /// Used when reopening a closed or ghost slot so the 3-second tombstone does
    /// not filter out the tab if a poll happens immediately after reopen.
    func cancelRecentlyClosedTombstone(browserName: String, url: String) {
        if let idx = recentlyClosedTabs.firstIndex(where: { $0.browserName == browserName && $0.url == url }) {
            recentlyClosedTabs.remove(at: idx)
        }
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
            if tab.type == .tab, !tab.isGhost,
               let idx = remaining.firstIndex(where: { $0.browserName == tab.browserName && $0.url == tab.url }) {
                remaining.remove(at: idx)
                continue
            }
            out.append(tab)
        }
        return out
    }

    /// Normalizes a URL for duplicate-tab detection. Duplicates require an
    /// exact URL match (same scheme, host, path, query, and fragment) — only
    /// surrounding whitespace is trimmed. Two tabs on the same page but with
    /// different query params (e.g. distinct session tokens, search terms,
    /// or anchors) are treated as different tabs, not duplicates.
    nonisolated static func normalizeDuplicateURL(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Groups live tabs by the same (browser, normalized URL) key used by the
    /// `@duplicate` filter. Returns only the keys with 2+ tabs, each mapped to
    /// its member count — the shared source of truth for both the
    /// `@duplicate` results filter and the `duplicateTabCount` tally.
    nonisolated static func duplicateGroupCounts(in tabs: [BrowserSearchResult]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for tab in tabs where tab.type == .tab {
            counts[tab.browserName + "|" + normalizeDuplicateURL(tab.url), default: 0] += 1
        }
        return counts.filter { $0.value >= 2 }
    }

    /// Total number of tabs that are part of a duplicate group (i.e. summing
    /// group sizes, not the number of distinct duplicated pages).
    nonisolated static func duplicateTabCount(in tabs: [BrowserSearchResult]) -> Int {
        duplicateGroupCounts(in: tabs).values.reduce(0, +)
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

    /// Convenience accessor for code that needs to reach the service without a
    /// reference to `AppState` — e.g. `SyncService`.
    @MainActor static var shared: BrowserTabService { AppState.shared.browserService }

    func backend(for result: BrowserSearchResult) -> (any BrowserBackend)? {
        backends.first(where: { $0.appName == result.browserName })
    }

    /// Opens a `.sent` (iPhone-shared) link. Unlike bookmarks/history,
    /// `result.browserName` holds the *source device* label ("iPhone") for
    /// display, not a real backend name — so `backend(for:)` never matches.
    /// The target browser instead comes from the sender's choice on iOS
    /// (`result.profileName`, threaded through from `preferBrowser`), falling
    /// back to the same default the "search the web" flow uses.
    func openSentLink(_ result: BrowserSearchResult) {
        guard let backend = result.profileName.flatMap({ backend(for: $0) }) ?? resolvedWebSearchBackend() else { return }
        // `result.profileName` here is the iOS-chosen *browser name*, not a
        // Chromium profile directory — rebuild the result with it cleared so
        // `ChromiumBackend.openURL` doesn't try `--profile-directory="Safari"`.
        let openable = BrowserSearchResult(
            title: result.title,
            url: result.url,
            browserName: backend.appName,
            type: result.type,
            timestamp: result.timestamp
        )
        Task.detached(priority: .userInitiated) { backend.openURL(openable) }
    }

    func backend(for browserName: String) -> (any BrowserBackend)? {
        backends.first(where: { $0.appName == browserName })
    }

    func remoteCloseTargetExists(_ payload: CloseTabPayload) -> Bool {
        guard let backend = backend(for: payload.browserName) else { return false }
        var activeTimes = lastActiveTimes
        let tabs = backend.fetchLiveTabs(
            fetchStart: Date(),
            activeTimes: &activeTimes,
            currentFlowSourceAppBundleIdentifier: currentFlowSourceAppBundleIdentifier
        )
        if let tabID = payload.tabID {
            return tabs.contains { $0.tabID == tabID }
        }
        return tabs.contains { tab in
            guard tab.url == payload.url else { return false }
            if let windowIndex = payload.windowIndex, tab.windowIndex != windowIndex {
                return false
            }
            if let tabIndex = payload.tabIndex, tab.tabIndex != tabIndex {
                return false
            }
            return true
        }
    }

    /// Bundle identifier of the user's actual macOS default browser (System
    /// Settings ▸ Desktop & Dock ▸ Default web browser). Used as a fallback
    /// signal below, since FastTab otherwise has no way to know it and would
    /// silently default to whichever tracked browser happens to be first.
    private var systemDefaultBrowserBundleIdentifier: String? {
        guard let httpsURL = URL(string: "https://"),
              let appURL = NSWorkspace.shared.urlForApplication(toOpen: httpsURL) else { return nil }
        return Bundle(url: appURL)?.bundleIdentifier
    }

    /// Browser a "Search the web" fallback (and a `.sent` iPhone-shared link
    /// with no explicit `preferBrowser`) should open in, in priority order:
    /// 1. Whichever browser the user invoked FastTab from — preserves intent
    ///    when FastTab was opened directly from a browser window.
    /// 2. The user's actual macOS default browser, if FastTab tracks it.
    /// 3. The first enabled/tracked browser, as a last resort (e.g. the real
    ///    default is a browser FastTab doesn't track, like Arc or Firefox).
    /// Finder is excluded — it's a backend for local file search, not a real
    /// browser a web search can open in.
    func resolvedWebSearchBackend() -> (any BrowserBackend)? {
        let realBrowsers = backends.filter { $0.appName != "Finder" }
        return realBrowsers.first(where: { $0.bundleIdentifier == currentFlowSourceAppBundleIdentifier })
            ?? realBrowsers.first(where: { $0.bundleIdentifier == systemDefaultBrowserBundleIdentifier })
            ?? realBrowsers.first
    }

    /// Name of the browser `openWebSearch` would currently target, for display
    /// in the fallback row before the user commits to it.
    var webSearchTargetBrowserName: String? {
        resolvedWebSearchBackend()?.appName
    }

    /// Opens a Google search for `query` in a new tab — the fallback offered
    /// when a typed query matches no tab, bookmark, or history item.
    func openWebSearch(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let targetBackend = resolvedWebSearchBackend() else { return }

        let searchURL = "https://www.google.com/search?q=\(webSearchQueryEncoded(trimmed))"
        let result = BrowserSearchResult(
            title: trimmed,
            url: searchURL,
            browserName: targetBackend.appName,
            type: .history,
            timestamp: Date()
        )

        logger.info("openWebSearch: browser=\(targetBackend.appName, privacy: .public) query='\(trimmed, privacy: .public)'")
        Task.detached(priority: .userInitiated) {
            targetBackend.openURL(result)
        }
    }

    private func refreshCachesIfNeeded(force: Bool) {
        InstalledWebAppCatalog.shared.rescanIfNeeded()

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

        refreshSearchAliases()

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
                var treeFolders: [BookmarkFolder] = []
                var diagnostics: [String] = []

                for backend in backends {
                    if Task.isCancelled {
                        return (bookmarks: [BrowserSearchResult](), history: [BrowserSearchResult](), treeFolders: [BookmarkFolder](), diagnostics: [String]())
                    }

                    diagnosticLogger.info("cache-refresh browser start app='\(backend.appName, privacy: .public)'")
                    let browserBookmarks = backend.fetchAllBookmarks()
                    let browserTree = backend.fetchBookmarkTree()
                    diagnosticLogger.info("cache-refresh bookmarks app='\(backend.appName, privacy: .public)' count=\(browserBookmarks.count)")
                    let browserHistory = backend.fetchRecentHistory(perBrowserLimit: historyLimit)
                    diagnosticLogger.info("cache-refresh history app='\(backend.appName, privacy: .public)' count=\(browserHistory.count)")

                    diagnostics.append("\(backend.appName):bookmarks=\(browserBookmarks.count),history=\(browserHistory.count)")
                    bookmarkResults.append(contentsOf: browserBookmarks)
                    historyResults.append(contentsOf: browserHistory)
                    treeFolders.append(contentsOf: browserTree)
                }

                return (
                    bookmarks: sortBrowserSearchResults(bookmarkResults),
                    history: sortBrowserSearchResults(historyResults),
                    treeFolders: treeFolders,
                    diagnostics: diagnostics
                )
            }.value

            if Task.isCancelled { return }

            cachedBookmarks = cachePayload.bookmarks
            cachedHistory = cachePayload.history
            cacheLastUpdatedAt = Date()
            BookmarkTreeStore.shared.setRootFolders(cachePayload.treeFolders)
            SyncService.shared.updateBookmarks(cachePayload.bookmarks)
            SyncService.shared.updateHistory(cachePayload.history)
            logger.info("Search cache refreshed. bookmarks={\(Self.typeBreakdown(cachePayload.bookmarks), privacy: .public)} history={\(Self.typeBreakdown(cachePayload.history), privacy: .public)} perBrowser='\(cachePayload.diagnostics.joined(separator: "; "), privacy: .public)'")

            // UI fetches can be browser-scoped, so only an all-backend refresh
            // is authoritative enough to reconcile CloudKit deletions.
            if !Task.isCancelled {
                self.refreshAuthoritativeLiveTabsAndPublish()
            }

            if lastIssuedQuery.isEmpty {
                logger.info("Search cache refresh applied without UI refetch (empty query).")
            } else {
                fetchResults(matching: lastIssuedQuery, filter: lastIssuedFilter)
            }
        }
    }
}
