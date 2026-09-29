import Foundation
import CloudKit
@testable import FastTab
import FastTabSync

// Fakes for `LiveTabSyncScenarioTests`: scriptable browsers, simulated time,
// and an in-memory CloudKit state zone, wired to the REAL pipeline
// (`LiveTabRefreshPipeline` + `LiveTabReader` + `LiveTabPublishState`).
// Only CloudKit transport and the command-bar UI are faked away.

// MARK: - Simulated time

/// A clock plus a queue of delayed actions. Nothing sleeps: `advance` jumps
/// straight to the next due action.
@MainActor
final class SimulatedClock {
    private(set) var now = Date(timeIntervalSince1970: 1_800_000_000)
    private var queue: [(fireAt: Date, order: Int, action: @MainActor () -> Void)] = []
    private var nextOrder = 0

    var pipelineClock: LiveTabRefreshPipeline.Clock {
        LiveTabRefreshPipeline.Clock(
            now: { [unowned self] in self.now },
            runAfter: { [unowned self] delay, action in self.runAfter(delay, action) }
        )
    }

    func runAfter(_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) {
        queue.append((now.addingTimeInterval(max(0, delay)), nextOrder, action))
        nextOrder += 1
    }

    /// Repeating timer (first fire after one interval), like `Timer(repeats:)`.
    func every(_ interval: TimeInterval, _ action: @escaping @MainActor () -> Void) {
        runAfter(interval) { [unowned self] in
            action()
            self.every(interval, action)
        }
    }

    /// Removes and returns the next action due at or before `end`, moving
    /// `now` to its fire time.
    func popNextDue(notAfter end: Date) -> (@MainActor () -> Void)? {
        guard let index = queue.indices.min(by: {
            (queue[$0].fireAt, queue[$0].order) < (queue[$1].fireAt, queue[$1].order)
        }), queue[index].fireAt <= end else { return nil }
        let due = queue.remove(at: index)
        now = max(now, due.fireAt)
        return due.action
    }

    func moveTo(_ date: Date) { now = max(now, date) }

    /// App quit: every pending timer dies with the process.
    func cancelAll() { queue.removeAll() }
}

/// Holds a simulated slow read open until the clock reaches its end, so a
/// read can overlap later timers and extension events.
@MainActor
final class SimulatedReadGate {
    private var isOpen = false
    private var waiter: CheckedContinuation<Void, Never>?

    func open() {
        isOpen = true
        waiter?.resume()
        waiter = nil
    }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiter = $0 }
    }
}

// MARK: - Fake browser

/// One open tab in a fake browser. `tabID` is what the extension would report.
struct FakeTab: Hashable {
    var url: String
    var title: String
    var tabID: Int
    var windowIndex: Int = 1
    var profileName: String?
}

/// Scriptable `BrowserBackend`. Record identity follows the real backends:
/// with `servesTabIDs` (extension path) tabs carry their tab ID; without it
/// (AppleScript path) they are named by window/tab position, which shifts
/// when an earlier tab closes.
final class FakeBrowserBackend: BrowserBackend, @unchecked Sendable {
    enum ReadBehavior { case readable, unreadable, notRunning }

    let appName: String
    var bundleIdentifier: String { "test.fake.\(appName)" }

    private let lock = NSLock()
    private var openTabs: [FakeTab]
    private var behavior = ReadBehavior.readable
    private var servesTabIDsStorage: Bool
    private var readCountStorage = 0

    init(_ appName: String, tabs: [FakeTab], servesTabIDs: Bool) {
        self.appName = appName
        self.openTabs = tabs
        self.servesTabIDsStorage = servesTabIDs
    }

    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    var tabs: [FakeTab] {
        get { locked { openTabs } }
        set { locked { openTabs = newValue } }
    }
    var readBehavior: ReadBehavior {
        get { locked { behavior } }
        set { locked { behavior = newValue } }
    }
    var servesTabIDs: Bool {
        get { locked { servesTabIDsStorage } }
        set { locked { servesTabIDsStorage = newValue } }
    }
    /// How many times the pipeline read this browser.
    var readCount: Int { locked { readCountStorage } }

    func closeTab(url: String) { tabs.removeAll { $0.url == url } }
    func quit() { readBehavior = .notRunning }

    func fetchLiveTabsOutcome(
        fetchStart: Date,
        activeTimes: inout [String: Date],
        currentFlowSourceAppBundleIdentifier: String?
    ) -> LiveTabFetchOutcome {
        let (tabs, behavior, servesTabIDs) = locked { () -> ([FakeTab], ReadBehavior, Bool) in
            readCountStorage += 1
            return (openTabs, self.behavior, servesTabIDsStorage)
        }
        switch behavior {
        case .unreadable: return .unreadable
        case .notRunning: return .fetched([])
        case .readable: break
        }
        var positionInWindow: [Int: Int] = [:]
        return .fetched(tabs.map { tab in
            let position = (positionInWindow[tab.windowIndex] ?? 0) + 1
            positionInWindow[tab.windowIndex] = position
            return BrowserSearchResult(
                title: tab.title,
                url: tab.url,
                browserName: appName,
                type: .tab,
                timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                windowIndex: tab.windowIndex,
                tabIndex: position,
                profileName: tab.profileName,
                tabID: servesTabIDs ? tab.tabID : nil
            )
        })
    }

    func fetchLiveTabs(fetchStart: Date, activeTimes: inout [String: Date], currentFlowSourceAppBundleIdentifier: String?) -> [BrowserSearchResult] {
        fetchLiveTabsOutcome(fetchStart: fetchStart, activeTimes: &activeTimes, currentFlowSourceAppBundleIdentifier: currentFlowSourceAppBundleIdentifier).tabs
    }
    func pollActiveTabKeys() -> [String] { [] }
    func fetchAllBookmarks() -> [BrowserSearchResult] { [] }
    func fetchRecentHistory(perBrowserLimit: Int) -> [BrowserSearchResult] { [] }
    func searchHistory(query: String, limit: Int) -> [BrowserSearchResult] { [] }
    func fetchFaviconData(pageURL: String) -> Data? { nil }
    func activateTab(_ result: BrowserSearchResult) {}
    func openURL(_ result: BrowserSearchResult) {}
    func deleteHistoryItem(_ result: BrowserSearchResult) {}
}

// MARK: - Fake CloudKit state zone

/// The server: `SyncedTab` records keyed by record name.
@MainActor
final class FakeStateZone {
    private(set) var records: [String: SyncedTab] = [:]
    private(set) var saveCount = 0
    private(set) var deleteCount = 0
    var writeCount: Int { saveCount + deleteCount }
    /// The next N deletes are lost in transit: not applied, never acknowledged
    /// (a change CKSyncEngine dropped, e.g. across a crash).
    var deletesToLose = 0

    func save(_ tab: SyncedTab) {
        saveCount += 1
        records[tab.id] = tab
    }

    /// Returns whether the delete was acknowledged.
    func delete(_ recordName: String) -> Bool {
        deleteCount += 1
        if deletesToLose > 0 {
            deletesToLose -= 1
            return false
        }
        records.removeValue(forKey: recordName)
        return true
    }

    /// A record left behind by an older build / naming scheme / reset.
    func seedStrandedRecord(_ tab: SyncedTab) { records[tab.id] = tab }
}

// MARK: - Simulated Mac app

/// FastTab on the Mac, minus CloudKit and UI: the production pipeline types,
/// driven by production cadences (10s active-tab poll, reconcile at startup
/// with 5s retries then every 10 min), publishing into `FakeStateZone`.
@MainActor
final class LiveTabSyncHarness {
    static let deviceID = "MAC-TEST"
    private static let activeTabPollInterval: TimeInterval = 10
    private static let reconcileStartupRetryDelay: TimeInterval = 5
    private static let reconcileStartupAttempts = 6

    let clock = SimulatedClock()
    let zone = FakeStateZone()
    let browsers: [FakeBrowserBackend]
    /// Survives `relaunch()`, like the UserDefaults-backed ledger.
    private var persistedLedger: Set<CKRecord.ID> = []
    private(set) var pipeline: LiveTabRefreshPipeline!
    private var publishState: LiveTabPublishState! {
        didSet { persistedLedger = publishState.publishedTabRecordIDs }
    }
    private var inFlightWork: [Task<Void, Never>] = []
    private(set) var reconcileRunCount = 0
    /// Simulated duration of every all-browser read (0 = instant). A slow
    /// read stays in flight while timers and extension events keep coming.
    /// Set it after `launch()`: a reconcile that must refresh first would wait
    /// on a gated read that only advancing the clock can finish.
    var readDuration: TimeInterval = 0
    private var slowReadsInProgress = 0

    init(_ browsers: [FakeBrowserBackend]) {
        self.browsers = browsers
    }

    // MARK: Lifecycle

    /// Mirrors `SyncService.start()` + `BrowserTabService` init: one
    /// authoritative refresh at launch, the active-tab poll, the reconcile
    /// timer and its startup attempts.
    func launch() async {
        publishState = LiveTabPublishState(deviceID: Self.deviceID, publishedTabRecordIDs: persistedLedger)
        let backends: [any BrowserBackend] = browsers
        pipeline = LiveTabRefreshPipeline(
            clock: clock.pipelineClock,
            hooks: LiveTabRefreshPipeline.Hooks(
                makeRead: { [unowned self] in
                    let readGate = self.startSimulatedReadGate()
                    return { () async -> LiveTabRead in
                        // Browsers are read when the gate opens (not at start):
                        // deterministic, since `drain` then awaits the read.
                        await readGate?.wait()
                        var activeTimes: [String: Date] = [:]
                        var audibleSeenAt: [String: Date] = [:]
                        let fetched = await LiveTabReader.fetchLiveTabOutcomesParallel(
                            backends: backends,
                            fetchStart: Date(),
                            baseline: [:],
                            activeTimes: &activeTimes,
                            currentFlowSourceAppBundleIdentifier: nil,
                            lastAudibleSeenAt: &audibleSeenAt
                        )
                        return LiveTabRead(tabs: fetched.tabs, unreadableBrowsers: fetched.unreadableBrowsers)
                    }
                },
                publish: { [unowned self] tabs, unreadableBrowsers in
                    self.publish(tabs, unreadableBrowsers: unreadableBrowsers)
                }
            )
        )
        pipeline.refreshNow()
        clock.every(Self.activeTabPollInterval) { [unowned self] in
            self.pipeline.idleTick()
        }
        clock.every(SyncService.tabReconcileInterval) { [unowned self] in
            self.track { _ = await self.reconcile() }
        }
        reconcileAtStartup(attempt: 1)
        await drain()
    }

    /// Quit + relaunch: timers, the in-memory snapshot and the fingerprint are
    /// gone; the persisted ledger and the server survive.
    func relaunch() async {
        await drain()
        clock.cancelAll()
        await launch()
    }

    private func reconcileAtStartup(attempt: Int) {
        track { [unowned self] in
            guard !(await self.reconcile()), attempt < Self.reconcileStartupAttempts else { return }
            self.clock.runAfter(Self.reconcileStartupRetryDelay) { self.reconcileAtStartup(attempt: attempt + 1) }
        }
    }

    // MARK: Simulated time

    /// Runs every timer due in the next `seconds`, awaiting each refresh /
    /// reconcile it starts before moving on.
    func advance(by seconds: TimeInterval) async {
        let end = clock.now.addingTimeInterval(seconds)
        await drain()
        while let action = clock.popNextDue(notAfter: end) {
            action()
            await drain()
        }
        clock.moveTo(end)
    }

    /// Advances one second at a time until the server matches the open tabs.
    /// Returns the simulated seconds it took, or nil if not within `limit`.
    func secondsUntilServerMatchesOpenTabs(within limit: TimeInterval) async -> TimeInterval? {
        var elapsed: TimeInterval = 0
        while elapsed <= limit {
            if serverMatchesOpenTabs { return elapsed }
            await advance(by: 1)
            elapsed += 1
        }
        return nil
    }

    /// Registered at read start (main actor), so the read's end time is fixed
    /// before `drain` can move the clock.
    private func startSimulatedReadGate() -> SimulatedReadGate? {
        guard readDuration > 0 else { return nil }
        let gate = SimulatedReadGate()
        slowReadsInProgress += 1
        clock.runAfter(readDuration) { [unowned self] in
            self.slowReadsInProgress -= 1
            gate.open()
        }
        return gate
    }

    private func track(_ work: @escaping @MainActor () async -> Void) {
        inFlightWork.append(Task { @MainActor in await work() })
    }

    /// Awaits in-flight refreshes (including follow-ups they start) and
    /// tracked work. A read still held by its `SimulatedReadGate` is left
    /// running: only advancing the clock can finish it.
    private func drain() async {
        while true {
            if slowReadsInProgress == 0, pipeline?.isRefreshInFlight == true {
                await pipeline?.waitForInFlightRefresh()
                continue
            }
            guard !inFlightWork.isEmpty else { return }
            let work = inFlightWork
            inFlightWork.removeAll()
            for task in work { await task.value }
        }
    }

    // MARK: Sync side (what SyncService does, minus CKSyncEngine)

    private func publish(_ tabs: [BrowserSearchResult], unreadableBrowsers: Set<String>) {
        guard let plan = publishState.planPublish(tabs, unreadableBrowsers: unreadableBrowsers) else { return }
        for tab in plan.tabsToSave { zone.save(tab) }
        let acknowledged = plan.recordIDsToDelete.filter { zone.delete($0.recordName) }
        publishState.acknowledgeDeletions(Set(acknowledged))
    }

    /// `SyncService.reconcileStateZoneTabs()`: refresh first when the snapshot
    /// is stale, then sweep the zone. Returns false when deferred.
    private func reconcile() async -> Bool {
        if !isSnapshotFresh { await pipeline.refreshNowAndWait() }
        guard isSnapshotFresh else { return false }
        reconcileRunCount += 1
        let plan = publishState.planReconcile(
            serverTabRecords: zone.records.values.map {
                LiveTabPublishState.ServerTabRecord(
                    recordID: CKRecord.ID(recordName: $0.id, zoneID: SyncConstants.stateZoneID),
                    browserName: $0.browserName
                )
            },
            snapshot: pipeline.snapshot,
            ghostTabs: [],
            isPendingSave: { _ in false }
        )
        let acknowledged = plan.orphanRecordIDs.filter { zone.delete($0.recordName) }
        publishState.acknowledgeDeletions(Set(acknowledged))
        return true
    }

    private var isSnapshotFresh: Bool {
        LiveTabRefreshPolicy.isSnapshotFreshForReconcile(
            isHydrated: pipeline.snapshot.isHydrated,
            lastFetchedAt: pipeline.snapshot.lastFetchedAt,
            now: clock.now,
            maxAge: SyncService.maxSnapshotAgeForReconcile
        )
    }

    // MARK: Extension events (what ExtensionBridge callbacks feed the pipeline)

    func extensionTabRemoved(_ browser: FakeBrowserBackend, url: String) {
        browser.closeTab(url: url)
        pipeline.noteExtensionTabRemoved()
    }

    func extensionTabUpserted(_ browser: FakeBrowserBackend, tab: FakeTab) {
        pipeline.noteExtensionTabUpserted(
            cachedTabs: pipeline.snapshot.tabs,
            browserName: browser.appName,
            tabID: tab.tabID,
            url: tab.url
        )
        if let index = browser.tabs.firstIndex(where: { $0.tabID == tab.tabID }) {
            browser.tabs[index] = tab
        } else {
            browser.tabs.append(tab)
        }
    }

    func extensionSnapshot(_ browser: FakeBrowserBackend) {
        pipeline.noteExtensionSnapshot(
            cachedTabs: pipeline.snapshot.tabs,
            browserName: browser.appName,
            snapshotTabIDs: browser.tabs.map(\.tabID)
        )
    }

    // MARK: Assertions

    /// This device's records on the server.
    var serverTabs: [SyncedTab] {
        zone.records.values.filter { $0.deviceID == Self.deviceID }
    }

    func serverTabs(of browser: FakeBrowserBackend) -> [SyncedTab] {
        serverTabs.filter { $0.browserName == browser.appName }
    }

    /// Exactly one record per open (non-private) tab, with its current title.
    /// Readable browsers only: an unreadable or quit browser has no truth to
    /// compare against beyond "its tabs are open" / "it has none".
    var serverMatchesOpenTabs: Bool {
        let expected = browsers.flatMap { browser -> [String] in
            guard browser.readBehavior != .notRunning else { return [] }
            return browser.tabs
                .filter { $0.profileName == nil }
                .map { "\(browser.appName)|\($0.url)|\($0.title)" }
        }
        let actual = serverTabs.map { "\($0.browserName)|\($0.url)|\($0.title)" }
        return actual.count == expected.count && Set(actual) == Set(expected)
    }

    var serverDescription: String {
        serverTabs.map { "\($0.id) \($0.url) \($0.title)" }.sorted().joined(separator: "\n")
    }
}

// MARK: - Fixtures

extension FakeTab {
    static func page(_ slug: String, id: Int, window: Int = 1) -> FakeTab {
        FakeTab(url: "https://\(slug).example/", title: slug.capitalized, tabID: id, windowIndex: window)
    }
}
