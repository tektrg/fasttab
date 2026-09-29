import Foundation
import OSLog

/// One completed read of every browser, handed from the (off-main) read to the
/// pipeline.
struct LiveTabRead: Sendable {
    var tabs: [BrowserSearchResult]
    /// Browsers whose read timed out or failed (see `LiveTabFetchOutcome`).
    var unreadableBrowsers: Set<String>
    /// Caller bookkeeping (e.g. recency timestamps) applied on the main actor
    /// only when this read is not superseded by a newer refresh.
    var commit: (@MainActor @Sendable () -> Void)?

    init(
        tabs: [BrowserSearchResult],
        unreadableBrowsers: Set<String> = [],
        commit: (@MainActor @Sendable () -> Void)? = nil
    ) {
        self.tabs = tabs
        self.unreadableBrowsers = unreadableBrowsers
        self.commit = commit
    }
}

/// The Mac half of the "tab closed on the Mac disappears from the iPhone"
/// chain: *when* to re-read every browser (idle cadence, extension events)
/// and *what* a completed read becomes (carry-forward of unreadable browsers →
/// authoritative snapshot → publish request).
///
/// Free of `BrowserTabService.shared`, `SyncService` and wall-clock timers so
/// the whole chain runs in tests on simulated time
/// (`LiveTabSyncScenarioTests`). `BrowserTabService` owns the production
/// instance and supplies the UI-side hooks.
@MainActor
final class LiveTabRefreshPipeline {
    /// Time source and delayed execution. Production: wall clock + `Task.sleep`.
    struct Clock {
        var now: @MainActor () -> Date
        var runAfter: @MainActor (_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> Void

        static let system = Clock(
            now: { Date() },
            runAfter: { delay, action in
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
                    action()
                }
            }
        )
    }

    struct Hooks {
        /// Called at refresh start (main actor) to capture inputs; returns the
        /// read to run off the main actor, or nil to skip this refresh.
        var makeRead: @MainActor () -> (@Sendable () async -> LiveTabRead)?
        /// Runs before the read starts (production: supersede a pending
        /// debounced UI publish — its snapshot is older than this one).
        var willStartRefresh: @MainActor () -> Void = {}
        /// UI-side processing of a completed read (tombstones, pin overlay,
        /// command-bar state). Returns the tabs the phone should see.
        var prepare: @MainActor (_ tabs: [BrowserSearchResult], _ unreadableBrowsers: Set<String>) -> [BrowserSearchResult] = { tabs, _ in tabs }
        /// Hands the authoritative tab list to the publisher.
        var publish: @MainActor (_ tabs: [BrowserSearchResult], _ unreadableBrowsers: Set<String>) -> Void
    }

    private let logger = Logger(subsystem: "com.trungluong.FastTab", category: "LiveTabRefreshPipeline")
    private let clock: Clock
    private let hooks: Hooks

    /// The last completed read of every browser — the only tab list trusted
    /// for publish deletes and state-zone reconciliation.
    private(set) var snapshot = AuthoritativeLiveTabSnapshot()
    /// When the last authoritative refresh started. Drives the idle cadence
    /// and the extension-event throttle (`LiveTabRefreshPolicy`).
    private(set) var lastRefreshStartedAt: Date?
    private var refreshTask: Task<Void, Never>?
    private var isExtensionEventRefreshScheduled = false
    /// When the newest phone-relevant extension event arrived.
    private var latestPhoneRelevantExtensionEventAt: Date?

    init(clock: Clock = .system, hooks: Hooks) {
        self.clock = clock
        self.hooks = hooks
    }

    // MARK: - Triggers

    /// Called on every active-tab poll tick (production: every ~10s, suspended
    /// during sleep). AppleScript browsers produce no close events, so this is
    /// what keeps the phone current while FastTab sits idle. No-change runs
    /// skip CloudKit via the publish fingerprint.
    func idleTick() {
        guard LiveTabRefreshPolicy.shouldRunIdleRefresh(lastRefreshStartedAt: lastRefreshStartedAt, now: clock.now()) else { return }
        logger.info("Idle authoritative tab refresh.")
        refreshNow()
    }

    /// Extension `tabRemoved`: always changes the phone's tab list.
    func noteExtensionTabRemoved() {
        schedulePhoneRelevantExtensionRefresh()
    }

    /// Extension `tabUpserted`. Call BEFORE applying the update to
    /// `cachedTabs` (the decision compares against the old URL).
    func noteExtensionTabUpserted(cachedTabs: [BrowserSearchResult], browserName: String, tabID: Int, url: String) {
        guard LiveTabRefreshPolicy.upsertChangesPhoneTabList(
            cachedTabs: cachedTabs, browserName: browserName, tabID: tabID, url: url
        ) else { return }
        schedulePhoneRelevantExtensionRefresh()
    }

    /// Extension full snapshot (sent on every window focus change). Call
    /// BEFORE applying it to `cachedTabs`.
    func noteExtensionSnapshot(cachedTabs: [BrowserSearchResult], browserName: String, snapshotTabIDs: [Int]) {
        guard LiveTabRefreshPolicy.snapshotChangesPhoneTabList(
            cachedTabs: cachedTabs, browserName: browserName, snapshotTabIDs: snapshotTabIDs
        ) else { return }
        schedulePhoneRelevantExtensionRefresh()
    }

    /// Extension events only patch local state (`cachedLiveTabs` can be a
    /// partial view, and the publish deletes by ledger), so events that change
    /// the phone's tab list schedule an authoritative refresh instead of
    /// publishing directly. Coalesced and throttled: a burst becomes one
    /// refresh, at most one per `extensionEventMinimumInterval`, skipped when
    /// another refresh already started after the newest event.
    private func schedulePhoneRelevantExtensionRefresh() {
        latestPhoneRelevantExtensionEventAt = clock.now()
        guard !isExtensionEventRefreshScheduled else { return }
        isExtensionEventRefreshScheduled = true
        let delay = LiveTabRefreshPolicy.extensionEventRefreshDelay(
            lastRefreshStartedAt: lastRefreshStartedAt,
            now: clock.now()
        )
        clock.runAfter(delay) { [weak self] in
            guard let self else { return }
            self.isExtensionEventRefreshScheduled = false
            guard let latestEventAt = self.latestPhoneRelevantExtensionEventAt,
                  LiveTabRefreshPolicy.shouldRunPendingExtensionEventRefresh(
                      latestEventAt: latestEventAt,
                      lastRefreshStartedAt: self.lastRefreshStartedAt
                  ) else {
                self.logger.info("Extension-event refresh skipped: a newer authoritative refresh already covers it.")
                return
            }
            self.logger.info("Authoritative refresh triggered by extension tab event.")
            self.refreshNow()
        }
    }

    // MARK: - Refresh

    /// Re-reads every browser and publishes the result. Supersedes (cancels)
    /// a refresh still in flight: only the newest read may publish.
    func refreshNow() {
        refreshTask?.cancel()
        lastRefreshStartedAt = clock.now()
        hooks.willStartRefresh()
        guard let read = hooks.makeRead() else { return }
        refreshTask = Task(priority: .utility) { [weak self] in
            let result = await read()
            guard !Task.isCancelled, let self else { return }
            self.complete(result)
        }
    }

    /// Runs a refresh and waits for it to finish (or be superseded). Used by
    /// reconciliation when its snapshot is stale.
    func refreshNowAndWait() async {
        refreshNow()
        await waitForInFlightRefresh()
    }

    func waitForInFlightRefresh() async {
        await refreshTask?.value
    }

    private func complete(_ read: LiveTabRead) {
        // A timed-out/failed browser read is "unknown", not "zero tabs": keep
        // that browser's previous authoritative tabs so the publish does not
        // delete them from the phone.
        let tabs = LiveTabRefreshPolicy.carryingForwardUnreadableBrowsers(
            fetched: read.tabs,
            unreadableBrowsers: read.unreadableBrowsers,
            previous: snapshot.tabs
        )
        if !read.unreadableBrowsers.isEmpty {
            logger.error("Authoritative refresh kept previous tabs for unreadable browsers: \(read.unreadableBrowsers.sorted().joined(separator: ","), privacy: .public)")
        }
        read.commit?()
        let phoneTabs = hooks.prepare(tabs, read.unreadableBrowsers)
        snapshot.applyAllBackends(phoneTabs, unreadableBrowsers: read.unreadableBrowsers, fetchedAt: clock.now())
        hooks.publish(phoneTabs, read.unreadableBrowsers)
    }
}
