import Foundation
import CloudKit
import OSLog
import FastTabSync

@MainActor
final class SyncService: NSObject, ObservableObject {
    static let shared = SyncService()

    let logger = Logger(subsystem: "com.trungluong.FastTab", category: "SyncService")

    let deviceID: String
    let deviceName: String
    let deviceModel: String

    var syncEngine: CKSyncEngine?
    private lazy var syncSendCoordinator = SyncSendCoordinator { [weak self] in
        await self?.performPendingChangesSend()
    }
    private let container: CKContainer
    let database: CKDatabase
    private let stateFileURL: URL
    /// `~/Library/Application Support/com.trungluong.FastTab`.
    let fastTabSupportDirectory: URL
    let commandJournal: SyncCommandJournal

    // In-memory cache of records to be supplied to CKSyncEngine recordProvider
    var pendingRecordsToSave: [CKRecord.ID: CKRecord] = [:]
    // Server-backed records retain CloudKit system fields such as change tags.
    // Domain updates must be applied to these objects instead of recreating IDs.
    var serverRecordsByID: [CKRecord.ID: CKRecord] = [:]

    /// Live-tab publish ledger, fingerprint skip and reconcile decisions (no
    /// CloudKit I/O). Every ledger change is persisted, so deletes of tabs
    /// published before a relaunch still happen.
    var liveTabPublishState: LiveTabPublishState {
        didSet {
            guard liveTabPublishState.publishedTabRecordIDs != oldValue.publishedTabRecordIDs else { return }
            Self.persistPublishedTabRecordIDs(liveTabPublishState.publishedTabRecordIDs, deviceID: deviceID)
        }
    }
    private var lastPublishedBookmarkHashes: [String: String] = [:]
    private var lastPublishedHistoryHashes: [String: String] = [:]
    private var lastPublishedTabOrderHash: String = ""
    var tabStatsPublishState = TabStatsPublishState()

    private var tabDebounceTask: Task<Void, Never>?
    private var syncPollTimer: Timer?
    private var pendingCommandSweepTimer: Timer?
    private var isSweepingPendingCommands = false
    private var accountChangeObserver: NSObjectProtocol?
    private var lastDevicePublishAt: Date?
    private var isInitialized = false

    /// Live-tab publish coalescing. The command bar's debounced refresh and the
    /// authoritative all-browser refresh can both request a publish within
    /// milliseconds; these two fields make the newest request win exactly once
    /// per MainActor turn instead of letting two publishers interleave their
    /// record batches and undo each other's deletions.
    var pendingLiveTabs: [BrowserSearchResult]?
    /// Browsers whose read failed in `pendingLiveTabs`' snapshot; the publish
    /// must not delete their records (see `tabRecordIDsToDelete(...sparingBrowsers:...)`).
    var pendingLiveTabsUnreadableBrowsers: Set<String> = []
    var liveTabsPublishTask: Task<Void, Never>?

    /// Drives the periodic state-zone tab reconciliation.
    var tabReconcileTimer: Timer?

    /// Serializes `reconcileStateZoneTabs()` — the zone re-read suspends, so a
    /// timer tick arriving mid-reconcile must not start a second overlapping
    /// read.
    var isReconcilingTabs = false

    /// Live sync probe responder state (`SyncService+ServerProbe.swift`).
    var isListeningForServerProbe = false
    var isAnsweringServerProbe = false
    var queuedServerProbeRequest: SyncServerProbe.Request?
    /// The probe's own view of the state zone and its own change token —
    /// independent of CKSyncEngine's. Memory-only: every launch starts from a
    /// full walk.
    var serverProbeMirror = SyncServerProbe.ZoneMirror()
    var serverProbeChangeToken: CKServerChangeToken?
    var lastServerProbeCatchUp: SyncServerProbe.CatchUpResult?

    /// Set by the first CloudKit push this process actually receives.
    ///
    /// Proven, never assumed. Receiving pushes depends on a provisioning profile
    /// carrying the Push Notifications capability, and when it doesn't, nothing
    /// fails loudly — the pushes simply never arrive. Relaxing the poll on the
    /// *assumption* of push would make sync four times slower on exactly the
    /// builds where push is broken.
    private var hasReceivedCloudKitPush = false

    /// Cadence of the token-independent pending-command sweep. Deliberately
    /// slow: `CKSyncEngine`'s change feed is the delivery path, and this is only
    /// the net that catches commands the feed can no longer see (lost or
    /// invalidated change token, corrupted state file, account switch).
    nonisolated private static let pendingCommandSweepInterval: TimeInterval = 10 * 60

    /// Delay before the first sweep, so `CKSyncEngine`'s own startup fetch gets
    /// a head start and the common case never pays for the recovery scan.
    nonisolated private static let pendingCommandSweepStartupDelay: TimeInterval = 5

    // MARK: - Published Sync Health

    @Published private(set) var syncHealth: SyncHealth = .unknown
    @Published private(set) var lastSuccessfulSyncAt: Date?
    @Published private(set) var lastSyncErrorMessage: String?
    /// Outstanding un-acked work, read from `CKSyncEngine.state` — the durable
    /// queue that survives relaunch — rather than from `pendingRecordsToSave`,
    /// which only holds the *content* for those changes and is memory-only.
    @Published private(set) var pendingChangeCount: Int = 0

    private static let deviceIDDefaultsKey = "FastTab.SyncDeviceID"

    override init() {
        // Resolve or create stable device identifier
        if let existing = UserDefaults.standard.string(forKey: Self.deviceIDDefaultsKey), !existing.isEmpty {
            self.deviceID = existing
        } else {
            let newID = UUID().uuidString
            UserDefaults.standard.set(newID, forKey: Self.deviceIDDefaultsKey)
            self.deviceID = newID
        }

        self.deviceName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        self.deviceModel = Self.getMacModelName()

        self.container = CKContainer(identifier: SyncConstants.containerIdentifier)
        self.database = container.privateCloudDatabase

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let fastTabDir = appSupport.appendingPathComponent("com.trungluong.FastTab", isDirectory: true)
        try? FileManager.default.createDirectory(at: fastTabDir, withIntermediateDirectories: true)
        self.fastTabSupportDirectory = fastTabDir
        self.stateFileURL = fastTabDir.appendingPathComponent("sync_state.dat")
        self.commandJournal = SyncCommandJournal(
            fileURL: fastTabDir.appendingPathComponent("sync_command_journal.json")
        )
        self.liveTabPublishState = LiveTabPublishState(
            deviceID: deviceID,
            publishedTabRecordIDs: Self.loadPublishedTabRecordIDs(deviceID: deviceID)
        )

        super.init()

        logger.info("SyncService initialized. deviceID=\(self.deviceID, privacy: .public) name='\(self.deviceName, privacy: .public)' model='\(self.deviceModel, privacy: .public)'")
    }

    func start() {
        guard !isInitialized else { return }
        isInitialized = true

        setupSyncEngine()
        observeAccountChanges()
        refreshAccountStatus()
        publishDevice()
        fetchLatestChanges()
        Task { @MainActor in
            // AppState owns BrowserTabService.shared and is still initializing here.
            // Yield before resolving it to avoid recursively entering AppState.shared.
            await Task.yield()
            self.restoreExecutingCommands()
            BrowserTabService.shared.refreshAuthoritativeLiveTabsAndPublish()
        }
        startSyncPollTimer()
        startPendingCommandSweepTimer()
        startTabReconcileTimer()
        startServerProbeListener()
    }

    /// Poll cadence before any push has arrived: the poll is the *entire* sync
    /// mechanism then, so it stays tight.
    nonisolated private static let pollOnlyInterval: TimeInterval = 15.0
    /// Poll cadence once push has proven itself — a backstop for dropped pushes,
    /// not the primary path.
    nonisolated private static let pushBackedPollInterval: TimeInterval = 60.0

    nonisolated static func pollInterval(hasReceivedPush: Bool) -> TimeInterval {
        hasReceivedPush ? pushBackedPollInterval : pollOnlyInterval
    }

    private func startSyncPollTimer() {
        syncPollTimer?.invalidate()
        let interval = Self.pollInterval(hasReceivedPush: hasReceivedCloudKitPush)
        syncPollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let now = Date()
                if Self.shouldPublishDeviceHeartbeat(lastPublishedAt: self.lastDevicePublishAt, now: now) {
                    self.publishDevice(at: now)
                }
                self.fetchLatestChanges()
                self.refreshPendingChangeCount()
            }
        }
    }

    // MARK: - CKSyncEngine Setup

    private func setupSyncEngine() {
        var lastStateSerialization: CKSyncEngine.State.Serialization?
        if FileManager.default.fileExists(atPath: stateFileURL.path) {
            if let data = try? Data(contentsOf: stateFileURL) {
                lastStateSerialization = try? PropertyListDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
            }
        }

        let config = CKSyncEngine.Configuration(
            database: database,
            stateSerialization: lastStateSerialization,
            delegate: self
        )

        let engine = CKSyncEngine(config)
        self.syncEngine = engine
        restoreCompletedCommandOutbox()

        // Ensure custom zones exist
        ensureZonesExist()
    }

    private func ensureZonesExist() {
        guard let syncEngine else { return }

        let stateZone = CKRecordZone(zoneID: SyncConstants.stateZoneID)
        let commandsZone = CKRecordZone(zoneID: SyncConstants.commandsZoneID)

        syncEngine.state.add(pendingDatabaseChanges: [
            .saveZone(stateZone),
            .saveZone(commandsZone)
        ])
    }

    private func saveStateSerialization(_ serialization: CKSyncEngine.State.Serialization) {
        do {
            let data = try PropertyListEncoder().encode(serialization)
            try data.write(to: stateFileURL, options: .atomic)
        } catch {
            logger.error("Failed to save sync engine state: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Device State

    func publishDevice() {
        publishDevice(at: Date())
    }

    private func publishDevice(at publishedAt: Date) {
        guard let syncEngine else { return }

        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let device = SyncedDevice(
            id: deviceID,
            name: deviceName,
            modelName: deviceModel,
            lastSeenAt: publishedAt,
            appVersion: appVersion,
            kind: .mac
        )

        let recordID = CKRecord.ID(recordName: device.id, zoneID: SyncConstants.stateZoneID)
        let record = serverRecordsByID[recordID].map { device.applying(to: $0) }
            ?? device.toRecord(zoneID: SyncConstants.stateZoneID)
        pendingRecordsToSave[record.recordID] = record
        lastDevicePublishAt = publishedAt

        syncEngine.state.add(pendingRecordZoneChanges: [
            .saveRecord(record.recordID)
        ])
        logger.info("Queued device record publish for \(self.deviceName, privacy: .public)")
        sendPendingChanges()
    }

    // MARK: - Live Tabs Publishing

    func updateLiveTabs(_ tabs: [BrowserSearchResult], unreadableBrowsers: Set<String> = []) {
        tabDebounceTask?.cancel()
        tabDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5s debounce
            guard !Task.isCancelled, let self else { return }
            self.requestLiveTabsPublish(tabs, unreadableBrowsers: unreadableBrowsers)
        }
    }

    /// Cancels a still-pending debounced live-tab publish (the command bar's
    /// UI path). Called by the authoritative all-browser refresh so a fresher
    /// snapshot is not later overwritten by an older one re-adding a tab that
    /// has since closed.
    func cancelPendingLiveTabsPublish() {
        tabDebounceTask?.cancel()
        tabDebounceTask = nil
    }

    func publishLiveTabsNow(_ tabs: [BrowserSearchResult], unreadableBrowsers: Set<String> = []) {
        guard let syncEngine else { return }

        guard let plan = liveTabPublishState.planPublish(tabs, unreadableBrowsers: unreadableBrowsers) else {
            logger.info("Live tabs sync skipped (content unchanged). tabCount=\(tabs.count)")
            return
        }

        var pendingChanges: [CKSyncEngine.PendingRecordZoneChange] = []
        for syncedTab in plan.tabsToSave {
            // Build on the server copy (keeps its change tag) so the save
            // updates rather than re-creates the record.
            let recordID = CKRecord.ID(recordName: syncedTab.id, zoneID: SyncConstants.stateZoneID)
            let record: CKRecord
            if let serverRecord = serverRecordsByID[recordID],
               serverRecord.recordType == SyncedTab.recordType {
                record = syncedTab.applying(to: serverRecord)
            } else {
                record = syncedTab.toRecord(zoneID: SyncConstants.stateZoneID)
            }
            pendingRecordsToSave[record.recordID] = record
            pendingChanges.append(.saveRecord(record.recordID))
        }
        for deleteID in plan.recordIDsToDelete {
            pendingChanges.append(.deleteRecord(deleteID))
            pendingRecordsToSave.removeValue(forKey: deleteID)
        }

        if !pendingChanges.isEmpty {
            syncEngine.state.add(pendingRecordZoneChanges: pendingChanges)
            logger.info("Live tabs sync queued: \(plan.tabsToSave.count) to save, \(plan.recordIDsToDelete.count) to delete")
            sendPendingChanges()
        }
    }

    // MARK: - Bookmarks Publishing

    func updateBookmarks(_ bookmarks: [BrowserSearchResult]) {
        guard let syncEngine else { return }

        // Group bookmarks by browser and profile
        var grouped: [String: [SyncedBookmarkItem]] = [:]
        for bm in bookmarks where bm.type == .bookmark {
            let browser = bm.browserName
            let profile = bm.profileName ?? "Default"
            let groupKey = "\(browser)|\(profile)"

            let item = SyncedBookmarkItem(
                id: bm.bookmarkID ?? bm.url,
                title: bm.title,
                url: bm.url,
                folderPath: bm.folderPath,
                dateAdded: bm.timestamp
            )
            grouped[groupKey, default: []].append(item)
        }

        var pendingChanges: [CKSyncEngine.PendingRecordZoneChange] = []

        for (groupKey, items) in grouped {
            let parts = groupKey.split(separator: "|", maxSplits: 1).map(String.init)
            let browser = parts.first ?? "Browser"
            let profile = parts.count > 1 ? parts[1] : "Default"

            let blob = SyncedBookmarkBlob(
                deviceID: deviceID,
                browserName: browser,
                profileName: profile,
                bookmarks: items
            )

            // Content-hash check to avoid redundant uploads
            if lastPublishedBookmarkHashes[blob.id] == blob.contentHash {
                continue
            }

            let recordID = CKRecord.ID(recordName: blob.id, zoneID: SyncConstants.stateZoneID)
            let record = serverRecordsByID[recordID].flatMap { blob.applying(to: $0) }
                ?? blob.toRecord(zoneID: SyncConstants.stateZoneID)
            if let record {
                lastPublishedBookmarkHashes[blob.id] = blob.contentHash
                pendingRecordsToSave[record.recordID] = record
                pendingChanges.append(.saveRecord(record.recordID))
            }
        }

        if !pendingChanges.isEmpty {
            syncEngine.state.add(pendingRecordZoneChanges: pendingChanges)
            logger.info("Bookmarks sync queued: \(pendingChanges.count) blobs modified")
            sendPendingChanges()
        }
    }

    // MARK: - History Publishing

    func updateHistory(_ history: [BrowserSearchResult]) {
        guard let syncEngine else { return }

        // Group history by browser, take newest 500 per browser
        var grouped: [String: [SyncedHistoryEntry]] = [:]
        for h in history where h.type == .history {
            let browser = h.browserName
            let entry = SyncedHistoryEntry(
                title: h.title,
                url: h.url,
                lastVisitedAt: h.timestamp
            )
            grouped[browser, default: []].append(entry)
        }

        var pendingChanges: [CKSyncEngine.PendingRecordZoneChange] = []

        for (browser, entries) in grouped {
            let cappedEntries = Array(entries.prefix(500))
            let slice = SyncedHistorySlice(
                deviceID: deviceID,
                browserName: browser,
                entries: cappedEntries
            )

            // Simple hash check using entry count + newest timestamp
            let newestDate = cappedEntries.first?.lastVisitedAt.timeIntervalSince1970 ?? 0
            let historySignature = "\(cappedEntries.count)_\(newestDate)"
            if lastPublishedHistoryHashes[slice.id] == historySignature {
                continue
            }

            let recordID = CKRecord.ID(recordName: slice.id, zoneID: SyncConstants.stateZoneID)
            let record = serverRecordsByID[recordID].flatMap { slice.applying(to: $0) }
                ?? slice.toRecord(zoneID: SyncConstants.stateZoneID)
            if let record {
                lastPublishedHistoryHashes[slice.id] = historySignature
                pendingRecordsToSave[record.recordID] = record
                pendingChanges.append(.saveRecord(record.recordID))
            }
        }

        if !pendingChanges.isEmpty {
            syncEngine.state.add(pendingRecordZoneChanges: pendingChanges)
            logger.info("History sync queued: \(pendingChanges.count) slices modified")
            sendPendingChanges()
        }
    }

    // MARK: - Tab Order Publishing

    func updateTabOrder(_ slots: [OrderedTabSlot]) {
        guard let syncEngine else { return }

        let syncedSlots = slots.map { slot in
            SyncedOrderedSlot(
                slotID: slot.slotID,
                matchKey: slot.matchKey,
                title: slot.title,
                url: slot.url,
                browserName: slot.browserName,
                profileName: slot.profileName,
                state: slot.state.rawValue,
                ghostedAt: slot.ghostedAt,
                isPinned: slot.isPinned
            )
        }

        let tabOrder = SyncedTabOrder(deviceID: deviceID, slots: syncedSlots)
        guard tabOrder.contentHash != lastPublishedTabOrderHash else {
            return
        }

        let recordID = CKRecord.ID(recordName: tabOrder.id, zoneID: SyncConstants.stateZoneID)
        let record = serverRecordsByID[recordID].flatMap { tabOrder.applying(to: $0) }
            ?? tabOrder.toRecord(zoneID: SyncConstants.stateZoneID)

        pendingRecordsToSave[recordID] = record
        syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
        lastPublishedTabOrderHash = tabOrder.contentHash
        logger.info("Tab order sync queued: \(syncedSlots.count) slots (hash: \(tabOrder.contentHash.prefix(8), privacy: .public))")
        sendPendingChanges()
    }

    // MARK: - Command Response Publishing

    func pushCommandResult(_ command: SyncCommand) {
        do {
            try commandJournal.storeCompletedResponse(command)
        } catch {
            logger.error("Failed to persist command response \(command.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        guard let syncEngine else { return }

        let recordID = CKRecord.ID(recordName: command.id, zoneID: SyncConstants.commandsZoneID)
        let record: CKRecord
        if let serverRecord = serverRecordsByID[recordID],
           serverRecord.recordType == SyncCommand.recordType {
            record = command.applying(to: serverRecord)
        } else {
            record = command.toRecord(zoneID: SyncConstants.commandsZoneID)
        }
        pendingRecordsToSave[record.recordID] = record
        syncEngine.state.add(pendingRecordZoneChanges: [
            .saveRecord(record.recordID)
        ])
        logger.info("Pushed command result id=\(command.id, privacy: .public) status=\(command.status.rawValue, privacy: .public)")
        sendPendingChanges()
    }

    private func restoreCompletedCommandOutbox() {
        guard let syncEngine else { return }
        let responses = commandJournal.completedResponses
        guard !responses.isEmpty else { return }
        let records = responses.map { $0.toRecord(zoneID: SyncConstants.commandsZoneID) }
        for record in records {
            pendingRecordsToSave[record.recordID] = record
        }
        syncEngine.state.add(pendingRecordZoneChanges: records.map { .saveRecord($0.recordID) })
        logger.info("Restored \(records.count) durable command responses into CKSyncEngine")
    }

    private func restoreExecutingCommands() {
        let interruptedCommands = commandJournal.executingCommands
        guard !interruptedCommands.isEmpty else { return }

        for command in interruptedCommands {
            if let terminalResponse = Self.terminalResponseForInterruptedCommand(command) {
                pushCommandResult(terminalResponse)
            } else {
                // closeTab is intentionally re-entered through the normal
                // reconcileExecuting path; already-absent is treated as done.
                handleIncomingCommand(command)
            }
        }
        logger.info("Recovered \(interruptedCommands.count) interrupted commands from durable journal")
    }

    // MARK: - Sync Operations

    func sendPendingChanges() {
        guard syncEngine != nil else { return }
        let syncSendCoordinator = syncSendCoordinator
        Task {
            await syncSendCoordinator.requestSend()
        }
    }

    private func performPendingChangesSend() async {
        guard let syncEngine else { return }
        do {
            try await syncEngine.sendChanges()
            logger.info("Triggered CKSyncEngine sendChanges")
            applySyncSuccess()
        } catch {
            logger.error("CKSyncEngine sendChanges error: \(error.localizedDescription, privacy: .public)")
            applySyncFailure(error)
        }
    }

    /// CloudKit's silent push, forwarded by `AppDelegate`. The only event-driven
    /// trigger in the whole sync path — everything else is a timer.
    ///
    /// The menu-bar app is always running, so on the Mac this is genuinely
    /// realtime; there is no background-execution budget to negotiate with.
    func handleRemoteNotification(_ userInfo: [AnyHashable: Any]) {
        guard CloudKitPushRouting.decision(forRemoteNotification: userInfo) == .fetchChanges else {
            logger.debug("Ignoring a remote notification that is not for our CloudKit container")
            return
        }

        if !hasReceivedCloudKitPush {
            hasReceivedCloudKitPush = true
            // Restart rather than leave the tight schedule running: this is the
            // moment we learn push works, and the poll's job shrinks to a backstop.
            startSyncPollTimer()
            logger.info("First CloudKit push received; poll relaxed to \(Self.pushBackedPollInterval, privacy: .public)s")
        }

        fetchLatestChanges()
    }

    func fetchLatestChanges() {
        guard let syncEngine else { return }
        Task {
            do {
                try await syncEngine.fetchChanges()
                self.logger.info("Triggered CKSyncEngine fetchChanges")
                self.applySyncSuccess()
            } catch {
                self.logger.error("CKSyncEngine fetchChanges error: \(error.localizedDescription, privacy: .public)")
                self.applySyncFailure(error)
            }
        }
    }

    // MARK: - Sync Health

    private func observeAccountChanges() {
        guard accountChangeObserver == nil else { return }
        accountChangeObserver = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshAccountStatus()
            }
        }
    }

    /// Reads the iCloud account status and publishes it.
    ///
    /// This is the only place the app can learn "the user is signed out" or
    /// "iCloud is restricted on this Mac". Without it every CloudKit call just
    /// fails into `os_log` and the user sees sync silently do nothing.
    private func refreshAccountStatus() {
        Task { @MainActor in
            do {
                let accountStatus = try await self.container.accountStatus()
                let health = SyncHealthDiagnostics.health(forAccountStatus: accountStatus)
                self.syncHealth = health
                if !health.isBlocked {
                    self.lastSyncErrorMessage = nil
                }
                self.logger.info("iCloud account status: \(String(describing: accountStatus), privacy: .public) health=\(health.shortLabel, privacy: .public)")
            } catch {
                self.applySyncFailure(error)
            }
        }
    }

    /// A completed CloudKit round trip proves the account works, so this also
    /// clears any previous `.failing` — a transient network blip must never
    /// latch the UI into a permanent error state.
    func applySyncSuccess(at completedAt: Date = Date()) {
        syncHealth = .ok
        lastSuccessfulSyncAt = completedAt
        lastSyncErrorMessage = nil
        refreshPendingChangeCount()
    }

    func applySyncFailure(_ error: Error) {
        let message = SyncHealthDiagnostics.userPresentableMessage(for: error)
        syncHealth = .failing(message)
        lastSyncErrorMessage = message
        refreshPendingChangeCount()
    }

    private func refreshPendingChangeCount() {
        pendingChangeCount = syncEngine?.state.pendingRecordZoneChanges.count ?? 0
    }

    // MARK: - Pending Command Recovery Sweep

    private func startPendingCommandSweepTimer() {
        pendingCommandSweepTimer?.invalidate()
        pendingCommandSweepTimer = Timer.scheduledTimer(
            withTimeInterval: Self.pendingCommandSweepInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sweepPendingCommands()
            }
        }

        let startupDelayNanoseconds = UInt64(Self.pendingCommandSweepStartupDelay * 1_000_000_000)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: startupDelayNanoseconds)
            self?.sweepPendingCommands()
        }
    }

    private func sweepPendingCommands() {
        guard syncEngine != nil, !isSweepingPendingCommands else { return }
        isSweepingPendingCommands = true
        Task { @MainActor in
            await self.scanCommandsZoneForPendingWork()
            self.isSweepingPendingCommands = false
        }
    }

    /// Re-reads the whole commands zone with a fresh change token and replays
    /// anything still pending for this Mac.
    ///
    /// Token-independent on purpose. Normal delivery rides `CKSyncEngine`'s
    /// incremental change token; if that token is ever lost or invalidated
    /// (corrupted state file, `changeTokenExpired`, account switch) the commands
    /// it would have reported are missed *permanently*, because nothing else
    /// re-discovers them.
    ///
    /// Passing `nil` for the token returns every record in the zone and needs no
    /// schema support. A `CKQuery` filtered on `status`/`targetDeviceID` would be
    /// the obvious alternative and is a trap: it requires queryable indexes this
    /// container does not define, so it fails at runtime rather than at build
    /// time.
    ///
    /// Replay is safe because `handleIncomingCommand` is idempotent — the
    /// durable `SyncCommandJournal` short-circuits anything already executing,
    /// awaiting its answering write, or answered at any point inside the
    /// command's TTL.
    private func scanCommandsZoneForPendingWork() async {
        var changeToken: CKServerChangeToken?
        var scannedRecordCount = 0
        var replayedCommandCount = 0

        while true {
            do {
                let zoneChanges = try await database.recordZoneChanges(
                    inZoneWith: SyncConstants.commandsZoneID,
                    since: changeToken
                )
                let records = zoneChanges.modificationResultsByID.values
                    .compactMap { try? $0.get().record }
                scannedRecordCount += records.count

                // Retain the server change tags: any later write to these
                // records must be an update, not a losing create.
                for record in records {
                    serverRecordsByID[record.recordID] = record
                }

                let replayableCommands = IncomingCommandFilter.redeliverableCommands(
                    in: records,
                    deviceID: deviceID
                )
                replayedCommandCount += replayableCommands.count
                for command in replayableCommands {
                    handleIncomingCommand(command)
                }

                guard zoneChanges.moreComing else { break }
                changeToken = zoneChanges.changeToken
            } catch {
                if SyncHealthDiagnostics.isExpectedMissingZone(error) {
                    logger.info("Pending-command sweep skipped: commands zone does not exist yet")
                } else {
                    logger.error("Pending-command sweep failed: \(error.localizedDescription, privacy: .public)")
                    applySyncFailure(error)
                }
                return
            }
        }

        logger.info("Pending-command sweep scanned \(scannedRecordCount) records, replayed \(replayedCommandCount) commands")
        applySyncSuccess()
    }

    /// Reacts to records CloudKit reports as gone.
    ///
    /// Three pieces of local state assume a record still exists server-side, and
    /// each one breaks differently if it is not corrected:
    /// - `serverRecordsByID` / `pendingRecordsToSave` hold a stale change tag,
    ///   so the Mac keeps trying to update a record that is not there.
    /// - the tab publish ledger drives tab *deletes*; leaving a
    ///   server-deleted ID in it makes the Mac queue a delete for an absent
    ///   record, which fails and is re-queued indefinitely.
    /// - the content fingerprints say "already published", so the content would
    ///   never be re-uploaded. Clearing them is the other half of the fix:
    ///   dropping a ledger entry alone would leave a still-open tab invisible to
    ///   the phone until its tab set happened to change.
    private func applyFetchedDeletions(_ deletions: [CKDatabase.RecordZoneChange.Deletion]) {
        guard !deletions.isEmpty else { return }

        let deletedRecordIDs = Set(deletions.map(\.recordID))
        for recordID in deletedRecordIDs {
            serverRecordsByID.removeValue(forKey: recordID)
            pendingRecordsToSave.removeValue(forKey: recordID)
        }

        liveTabPublishState.forgetServerDeletedRecords(deletedRecordIDs)

        PairedPhoneStore.shared.forget(recordNames: deletions
            .filter { $0.recordType == SyncedDevice.recordType }
            .map(\.recordID.recordName))

        for deletion in deletions {
            switch deletion.recordType {
            case SyncedBookmarkBlob.recordType:
                lastPublishedBookmarkHashes.removeValue(forKey: deletion.recordID.recordName)
            case SyncedHistorySlice.recordType:
                lastPublishedHistoryHashes.removeValue(forKey: deletion.recordID.recordName)
            case SyncedTabStats.recordType:
                resetTabStatsPublishState()
            default:
                break
            }
        }

        logger.info("Applied \(deletions.count) fetched server deletions")
    }

    // MARK: - Helpers

    nonisolated private static func getMacModelName() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "Mac" }

        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let identifier = model.withUnsafeBufferPointer { ptr in
            ptr.baseAddress.map { String(cString: $0) } ?? "Mac"
        }

        if identifier.contains("MacBookPro") { return "MacBook Pro" }
        if identifier.contains("MacBookAir") { return "MacBook Air" }
        if identifier.contains("MacBook") { return "MacBook" }
        if identifier.contains("Macmini") { return "Mac mini" }
        if identifier.contains("MacStudio") { return "Mac Studio" }
        if identifier.contains("MacPro") { return "Mac Pro" }
        if identifier.contains("iMac") { return "iMac" }

        return identifier.isEmpty ? "Mac" : identifier
    }

    func resetPublishState() {
        liveTabPublishState.reset()
        lastPublishedBookmarkHashes.removeAll()
        lastPublishedHistoryHashes.removeAll()
        lastPublishedTabOrderHash = ""
        resetTabStatsPublishState()
        pendingRecordsToSave.removeAll()
        serverRecordsByID.removeAll()
    }

}

// MARK: - CKSyncEngineDelegate

extension SyncService: CKSyncEngineDelegate {
    nonisolated func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) {
        Task { @MainActor in
            switch event {
            case .stateUpdate(let update):
                self.saveStateSerialization(update.stateSerialization)

            case .accountChange(let change):
                self.logger.info("CKSyncEngine account change: \(String(describing: change.changeType), privacy: .public)")
                self.refreshAccountStatus()
                switch change.changeType {
                case .signIn:
                    self.resetPublishState()
                    self.publishDevice()
                    self.ensureZonesExist()
                case .switchAccounts:
                    self.resetPublishState()
                    self.publishDevice()
                    self.ensureZonesExist()
                case .signOut:
                    self.resetPublishState()
                @unknown default:
                    break
                }

            case .fetchedRecordZoneChanges(let fetchedChanges):
                for modification in fetchedChanges.modifications {
                    let record = modification.record
                    self.serverRecordsByID[record.recordID] = record
                    if record.recordType == SyncCommand.recordType {
                        if let command = SyncCommand(from: record) {
                            self.handleIncomingCommand(command)
                        }
                    }
                }
                PairedPhoneStore.shared.absorb(fetchedChanges.modifications.map(\.record))
                self.applyFetchedDeletions(fetchedChanges.deletions)

            case .sentRecordZoneChanges(let sentChanges):
                for saved in sentChanges.savedRecords {
                    self.pendingRecordsToSave.removeValue(forKey: saved.recordID)
                    self.serverRecordsByID[saved.recordID] = saved
                    if saved.recordType == SyncCommand.recordType {
                        do {
                            try self.commandJournal.acknowledgeCompletedResponse(
                                commandID: saved.recordID.recordName
                            )
                        } catch {
                            self.logger.error("Failed to acknowledge command response \(saved.recordID.recordName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        }
                    }
                }
                if !sentChanges.deletedRecordIDs.isEmpty {
                    // A reused record name (positional tabs) must be re-created
                    // fresh, not built on the deleted record's change tag.
                    for recordID in sentChanges.deletedRecordIDs {
                        self.serverRecordsByID.removeValue(forKey: recordID)
                    }
                    self.liveTabPublishState.acknowledgeDeletions(Set(sentChanges.deletedRecordIDs))
                }
                var queuedSaveRetry = false
                for failedSave in sentChanges.failedRecordSaves {
                    if let retryRecord = Self.recordForRetry(
                        intendedRecord: failedSave.record,
                        error: failedSave.error
                    ) {
                        self.serverRecordsByID[retryRecord.recordID] = retryRecord
                        self.pendingRecordsToSave[retryRecord.recordID] = retryRecord
                        syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(retryRecord.recordID)])
                        queuedSaveRetry = true
                        self.logger.info("Reconciled record conflict and queued retry for \(retryRecord.recordID.recordName, privacy: .public)")
                    } else {
                        self.logger.error("Failed to save record \(failedSave.record.recordID.recordName, privacy: .public): \(failedSave.error.localizedDescription, privacy: .public)")
                        // Quota and auth failures surface here rather than from
                        // sendChanges(), so this is where they become visible.
                        self.applySyncFailure(failedSave.error)
                    }
                }
                var queuedDeleteRetry = false
                for (recordID, error) in sentChanges.failedRecordDeletes {
                    syncEngine.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
                    queuedDeleteRetry = true
                    self.logger.error("Failed to delete record \(recordID.recordName, privacy: .public); queued retry: \(error.localizedDescription, privacy: .public)")
                }
                let queuedRecordRetry = Self.shouldRequestRecordRetrySend(
                    queuedSaveRetry: queuedSaveRetry,
                    queuedDeleteRetry: queuedDeleteRetry
                )
                if queuedRecordRetry {
                    self.sendPendingChanges()
                }

            case .sentDatabaseChanges(let databaseChanges):
                for failedSave in databaseChanges.failedZoneSaves {
                    self.logger.error("Failed to save zone \(failedSave.zone.zoneID.zoneName, privacy: .public): \(failedSave.error.localizedDescription, privacy: .public)")
                }

            case .fetchedDatabaseChanges,
                 .willFetchChanges,
                 .didFetchChanges,
                 .willFetchRecordZoneChanges,
                 .didFetchRecordZoneChanges,
                 .willSendChanges,
                 .didSendChanges:
                break

            @unknown default:
                break
            }
        }
    }

    nonisolated func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let (pendingChanges, records) = await MainActor.run {
            (syncEngine.state.pendingRecordZoneChanges, self.pendingRecordsToSave)
        }
        guard !pendingChanges.isEmpty else { return nil }

        // `pendingRecordsToSave` is memory-only while CKSyncEngine's pending
        // change list is durable, so a relaunch can leave a pending save with no
        // record behind it. Returning nil from the provider would drop it into a
        // silent void, so drop it deliberately and say so at error level.
        let batchPlan = SyncRecordBatchPlanner.plan(
            pendingChanges: pendingChanges,
            availableRecordIDs: Set(records.keys)
        )
        if !batchPlan.stalePendingSaves.isEmpty {
            await MainActor.run {
                syncEngine.state.remove(pendingRecordZoneChanges: batchPlan.stalePendingSaves)
                self.logger.error("Dropped \(batchPlan.stalePendingSaves.count) pending record saves with no cached content; the owning publisher will republish them")
                self.refreshPendingChangeCount()
            }
        }
        guard !batchPlan.deliverableChanges.isEmpty else { return nil }

        return await CKSyncEngine.RecordZoneChangeBatch(
            pendingChanges: batchPlan.deliverableChanges,
            recordProvider: { recordID in
                records[recordID]
            }
        )
    }
}
