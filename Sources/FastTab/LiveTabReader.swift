import Foundation

/// The live-tab read shared by the command bar and the authoritative (phone)
/// refresh: every browser backend read in parallel, with failed reads
/// reported instead of silently reading as "zero tabs".
/// Moved out of `BrowserTabService` unchanged so the sync pipeline
/// (`LiveTabRefreshPipeline`) and its scenario tests use the same read.
enum LiveTabReader {
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
    ///
    /// A browser whose read failed or timed out keeps its tabs from
    /// `previous` instead of reading as empty (every result can end up in
    /// `cachedLiveTabs` and from there on the phone); it is also reported in
    /// `unreadableBrowsers` so the publish spares its records.
    nonisolated static func fetchLiveTabsCarryingForwardUnreadable(
        backends: [any BrowserBackend],
        fetchStart: Date,
        baseline: [String: Date],
        activeTimes: inout [String: Date],
        currentFlowSourceAppBundleIdentifier: String?,
        lastAudibleSeenAt: inout [String: Date],
        previous: [BrowserSearchResult]
    ) async -> (tabs: [BrowserSearchResult], unreadableBrowsers: Set<String>) {
        let fetched = await fetchLiveTabOutcomesParallel(
            backends: backends,
            fetchStart: fetchStart,
            baseline: baseline,
            activeTimes: &activeTimes,
            currentFlowSourceAppBundleIdentifier: currentFlowSourceAppBundleIdentifier,
            lastAudibleSeenAt: &lastAudibleSeenAt
        )
        let tabs = LiveTabRefreshPolicy.carryingForwardUnreadableBrowsers(
            fetched: fetched.tabs,
            unreadableBrowsers: fetched.unreadableBrowsers,
            previous: previous
        )
        return (tabs, fetched.unreadableBrowsers)
    }

    /// The raw parallel read: every backend's tabs plus the browsers whose
    /// read failed or timed out (see `LiveTabFetchOutcome`).
    nonisolated static func fetchLiveTabOutcomesParallel(
        backends: [any BrowserBackend],
        fetchStart: Date,
        baseline: [String: Date],
        activeTimes: inout [String: Date],
        currentFlowSourceAppBundleIdentifier: String?,
        lastAudibleSeenAt: inout [String: Date]
    ) async -> (tabs: [BrowserSearchResult], unreadableBrowsers: Set<String>) {
        if backends.isEmpty { return ([], []) }

        let liveTabs: [BrowserSearchResult]
        var unreadableBrowsers: Set<String> = []
        if backends.count == 1 {
            let outcome = backends[0].fetchLiveTabsOutcome(
                fetchStart: fetchStart,
                activeTimes: &activeTimes,
                currentFlowSourceAppBundleIdentifier: currentFlowSourceAppBundleIdentifier
            )
            if outcome == .unreadable { unreadableBrowsers.insert(backends[0].appName) }
            liveTabs = outcome.tabs
        } else {
            let collected = await withTaskGroup(
                of: (browserName: String, outcome: LiveTabFetchOutcome, updates: [String: Date]).self
            ) { group in
                for backend in backends {
                    group.addTask {
                        if Task.isCancelled { return (backend.appName, .unreadable, [:]) }
                        var local = baseline
                        let outcome = backend.fetchLiveTabsOutcome(
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
                        return (backend.appName, outcome, updates)
                    }
                }
                var all: [(browserName: String, outcome: LiveTabFetchOutcome, updates: [String: Date])] = []
                for await item in group { all.append(item) }
                return all
            }

            var collectedTabs: [BrowserSearchResult] = []
            for entry in collected {
                if entry.outcome == .unreadable { unreadableBrowsers.insert(entry.browserName) }
                collectedTabs.append(contentsOf: entry.outcome.tabs)
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

        let annotated = annotatingPinnedAudibleTabs(liveTabs, lastAudibleSeenAt: &lastAudibleSeenAt, now: fetchStart)
        return (annotated, unreadableBrowsers)
    }
}
