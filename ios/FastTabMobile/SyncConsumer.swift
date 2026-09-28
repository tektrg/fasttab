import Foundation
import CloudKit
import OSLog
import UIKit
import FastTabSync

@MainActor
public final class SyncConsumer: NSObject, ObservableObject {
    public static let shared = SyncConsumer()

    let logger = Logger(subsystem: "app.theindie.FastTab", category: "SyncConsumer")

    public let deviceID: String
    public let deviceName: String

    var syncEngine: CKSyncEngine?
    private let container: CKContainer
    private let database: CKDatabase
    private let stateFileURL: URL

    /// Record bodies handed to `CKSyncEngine`'s record provider at send time.
    /// In-memory only — rebuilt from `commandOutbox` on every launch.
    /// Internal rather than private only so the delegate extension in
    /// SyncConsumer+SyncEngineDelegate.swift can reach it.
    var pendingRecordsToSave: [CKRecord.ID: CKRecord] = [:]

    /// Durable copy of every command CloudKit has not confirmed yet.
    private let commandOutbox: SyncCommandOutbox

    private var accountChangeObserver: NSObjectProtocol?
    private var hasStarted = false

    /// When this phone last queued its own `SyncedDevice` heartbeat — the
    /// record the Mac reads to say "iPhone connected". See
    /// SyncConsumer+DeviceHeartbeat.swift.
    var lastDevicePublishAt: Date?
    /// Server copy of this phone's device record, so a heartbeat updates it in
    /// place instead of colliding with it as a blind insert.
    var ownDeviceServerRecord: CKRecord?

    /// Drives the periodic pull while the app is on screen. Only alive between
    /// `startForegroundRefresh()` and `stopForegroundRefresh()`.
    private var foregroundRefreshTimer: Timer?

    @Published public private(set) var isSyncing: Bool = false
    @Published public private(set) var lastSyncError: String?
    /// Whether sync can work at all right now. Rendered by the UI.
    @Published public private(set) var syncHealth: SyncHealth = .unknown
    @Published public private(set) var lastSuccessfulSyncAt: Date?
    /// Outbox depth — "N changes waiting to reach your Mac".
    @Published public private(set) var pendingCommandCount: Int = 0

    private static let deviceIDDefaultsKey = "FastTabMobile.DeviceID"
    private static let stateFileName = "ios_sync_state.dat"

    /// How often an on-screen app pulls from CloudKit. Nothing wakes this app on
    /// a remote change yet — there is no push entitlement on either platform —
    /// so without this poll an open screen never updates at all.
    ///
    /// Deliberately a plain fixed interval: once push notifications land, this
    /// poll becomes a backstop and an adaptive schedule would be dead weight.
    private static let foregroundRefreshInterval: TimeInterval = 6

    public override init() {
        if let existing = UserDefaults.standard.string(forKey: Self.deviceIDDefaultsKey), !existing.isEmpty {
            self.deviceID = existing
        } else {
            let newID = UUID().uuidString
            UserDefaults.standard.set(newID, forKey: Self.deviceIDDefaultsKey)
            self.deviceID = newID
        }

        // Generic "iPhone" on iOS 16+ without the device-name entitlement;
        // still the right label, and the user's own name if ever granted.
        self.deviceName = UIDevice.current.name
        self.container = CKContainer(identifier: SyncConstants.containerIdentifier)
        self.database = container.privateCloudDatabase
        self.stateFileURL = AppGroupContainer.fileURL(forFileNamed: Self.stateFileName)
        self.commandOutbox = SyncCommandOutbox()

        super.init()

        self.pendingCommandCount = commandOutbox.pendingCount
    }

    public func start() {
        guard !hasStarted else { return }
        hasStarted = true

        setupSyncEngine()
        observeAccountChanges()
        // Armed here as well as on the scene-phase change: SwiftUI does not
        // deliver an `onChange` for the phase the app launches into, so a cold
        // launch would otherwise never start polling.
        startForegroundRefresh()
        // One ordered sequence: the account verdict must land before a send or
        // fetch can publish health, otherwise a no-op success can mask
        // "signed out". Anything the outbox restored goes out here too, even if
        // the user never touches the app again this launch.
        Task { await refreshNow() }
    }

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

        ensureZonesExist()
        restorePendingCommandOutbox()
    }

    func ensureZonesExist() {
        guard let syncEngine else { return }
        let stateZone = CKRecordZone(zoneID: SyncConstants.stateZoneID)
        let commandsZone = CKRecordZone(zoneID: SyncConstants.commandsZoneID)
        syncEngine.state.add(pendingDatabaseChanges: [
            .saveZone(stateZone),
            .saveZone(commandsZone)
        ])
    }

    func saveStateSerialization(_ serialization: CKSyncEngine.State.Serialization) {
        do {
            let data = try PropertyListEncoder().encode(serialization)
            try data.write(to: stateFileURL, options: .atomic)
        } catch {
            logger.error("Failed to save iOS sync engine state: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Account & Health

    private func observeAccountChanges() {
        guard accountChangeObserver == nil else { return }
        accountChangeObserver = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.refreshAccountStatus()
                self.fetchLatestChanges()
            }
        }
    }

    /// Asks CloudKit whether sync is even possible, so a signed-out phone says
    /// so instead of silently doing nothing forever.
    func refreshAccountStatus() async {
        do {
            let status = try await container.accountStatus()
            applyAccountHealth(SyncHealthMapping.health(forAccountStatus: status))
        } catch {
            markSyncFailed(error, whileDoing: "checking the iCloud account")
        }
    }

    private func applyAccountHealth(_ health: SyncHealth) {
        switch health {
        case .unknown:
            // CloudKit could not tell us. Keep whatever we already knew rather
            // than replacing a real error with "Checking iCloud…".
            break
        case .ok:
            // Only lift a *blocking* state here. A real transfer failure stays
            // visible until a transfer actually succeeds.
            if syncHealth.isBlocked || syncHealth == .unknown {
                syncHealth = .ok
                lastSyncError = nil
            }
        default:
            syncHealth = health
            lastSyncError = health.detail
        }
    }

    /// Whether a transfer should drive the visible "Syncing…" indicator.
    ///
    /// The periodic poll is `.silent`: it runs every few seconds, and flashing
    /// the spinner on every tick would make a perfectly healthy app read as
    /// permanently busy. Failures are still reported either way — a silent
    /// transfer is invisible while it works, not while it breaks.
    enum TransferVisibility {
        case userInitiated
        case silent
    }

    /// `isSyncing` reflects in-flight *user-initiated* transfers. Counted rather
    /// than assigned, so one finishing operation cannot clear the spinner while
    /// another is still running.
    private var visibleTransferCount = 0

    private func beginTransfer(_ visibility: TransferVisibility) {
        guard visibility == .userInitiated else { return }
        visibleTransferCount += 1
        isSyncing = true
    }

    private func endTransfer(_ visibility: TransferVisibility) {
        guard visibility == .userInitiated else { return }
        visibleTransferCount = max(0, visibleTransferCount - 1)
        isSyncing = visibleTransferCount > 0
    }

    func markSyncSucceeded() {
        lastSuccessfulSyncAt = Date()
        lastSyncError = nil
        syncHealth = .ok
    }

    func markSyncFailed(_ error: Error, whileDoing activity: String) {
        let message = SyncHealthMapping.message(forFailure: error)
        let health = SyncHealthMapping.health(forFailure: error)
        // Report transitions, not repetitions. The foreground poll retries every
        // few seconds, so an offline or signed-out phone would otherwise
        // re-publish and re-log an unchanged failure forever — and `@Published`
        // fires on assignment regardless of equality.
        guard message != lastSyncError || health != syncHealth else { return }
        lastSyncError = message
        syncHealth = health
        logger.error("iOS sync failed while \(activity, privacy: .public): \(error.localizedDescription, privacy: .public)")
    }

    // MARK: - Foreground Refresh

    /// Idempotent: repeated calls keep the existing schedule rather than
    /// stacking timers.
    public func startForegroundRefresh() {
        guard foregroundRefreshTimer == nil else { return }
        foregroundRefreshTimer = Timer.scheduledTimer(
            withTimeInterval: Self.foregroundRefreshInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.pollForRemoteChanges()
            }
        }
    }

    public func stopForegroundRefresh() {
        foregroundRefreshTimer?.invalidate()
        foregroundRefreshTimer = nil
    }

    /// The periodic tick. Silent by design — see `TransferVisibility`.
    ///
    /// Sends first: an outbox that was stuck behind a dead network gets retried
    /// without the user having to pull to refresh. A send with nothing queued
    /// never touches the network.
    private func pollForRemoteChanges() async {
        publishOwnDeviceIfDue()
        await performSend(visibility: .silent)
        await performFetch(visibility: .silent)
    }

    // MARK: - Push-Driven Sync

    /// CloudKit's silent push, forwarded by `PushNotificationAppDelegate`. The
    /// only trigger here that isn't a timer.
    ///
    /// Silent by design even though the app may be on screen: the user did not
    /// ask for this pull, so it should not raise the "Syncing…" indicator.
    ///
    /// A backgrounded iPhone gets these on iOS's terms, not ours — the system
    /// decides how many silent pushes an app is worth — and a force-quit app
    /// gets none at all. So this makes sync feel instant while the phone is in
    /// hand; the foreground poll remains the guarantee.
    public func handleRemoteNotification() async -> Bool {
        await performFetch(visibility: .silent)
    }

    // MARK: - Fetch & Send

    /// Fire-and-forget refresh for non-async callers.
    public func fetchLatestChanges() {
        Task { await performFetch(visibility: .userInitiated) }
    }

    /// Awaitable refresh, so a SwiftUI `.refreshable` spinner reflects the real
    /// round trip instead of finishing instantly.
    public func refreshNow() async {
        await refreshAccountStatus()
        // Pull-to-refresh doubles as "retry everything": re-arm anything the
        // outbox still holds in case the engine's pending changes were lost.
        restorePendingCommandOutbox()
        // Launch, every return to the foreground, and pull-to-refresh: the
        // moments the phone is demonstrably in use, so the Mac should know.
        publishOwnDeviceIfDue(interval: Self.userActivityHeartbeatFloor)
        await performSend(visibility: .userInitiated)
        await performFetch(visibility: .userInitiated)
    }

    public func sendPendingChanges() {
        Task { await performSend(visibility: .userInitiated) }
    }

    /// Push, then immediately pull. Used when the user has just asked the Mac to
    /// do something: that is the one moment they are actively waiting on an
    /// answer, so the reply to anything already in flight should not sit unread
    /// until the next tick.
    private func sendThenFetch() {
        Task {
            await performSend(visibility: .userInitiated)
            await performFetch(visibility: .userInitiated)
        }
    }

    /// Returns whether the pull actually completed. Callers that owe iOS a
    /// `UIBackgroundFetchResult` need the truth — an app that keeps claiming it
    /// did work it did not do gets its silent pushes throttled.
    @discardableResult
    private func performFetch(visibility: TransferVisibility) async -> Bool {
        guard let syncEngine else { return false }
        beginTransfer(visibility)
        do {
            try await syncEngine.fetchChanges()
            endTransfer(visibility)
            markSyncSucceeded()
            logger.info("Fetched CloudKit changes on iOS")
            return true
        } catch {
            endTransfer(visibility)
            markSyncFailed(error, whileDoing: "fetching changes")
            return false
        }
    }

    /// Sends are chained rather than run concurrently: two overlapping
    /// `sendChanges()` calls interleave their record batches and their writes to
    /// the published health properties.
    private var inFlightSend: Task<Void, Never>?

    private func performSend(visibility: TransferVisibility) async {
        let previousSend = inFlightSend
        let send = Task { @MainActor [weak self] in
            await previousSend?.value
            await self?.sendChangesNow(visibility: visibility)
        }
        inFlightSend = send
        await send.value
    }

    private func sendChangesNow(visibility: TransferVisibility) async {
        guard let syncEngine else { return }
        // A send with nothing queued always "succeeds" — it must not be allowed
        // to report a healthy sync on, say, a signed-out phone.
        let hadQueuedWork = !syncEngine.state.pendingRecordZoneChanges.isEmpty
            || !syncEngine.state.pendingDatabaseChanges.isEmpty
        guard hadQueuedWork else { return }

        beginTransfer(visibility)
        do {
            try await syncEngine.sendChanges()
            endTransfer(visibility)
            markSyncSucceeded()
            logger.info("Sent pending CloudKit changes on iOS")
        } catch {
            endTransfer(visibility)
            markSyncFailed(error, whileDoing: "sending changes")
        }
    }

    // MARK: - Outbound Commands

    public func sendOpenOnMac(url: String, title: String? = nil, preferBrowser: String? = nil, targetDeviceID: String = "") {
        let payload = OpenOnMacPayload(url: url, title: title, preferBrowser: preferBrowser)
        guard let payloadJSON = Self.encodedPayload(payload) else { return }

        queueCommand(SyncCommand(
            kind: .openOnMac,
            targetDeviceID: targetDeviceID,
            sourceDeviceName: deviceName,
            payloadJSON: payloadJSON
        ))
    }

    public func sendCloseTab(_ tab: SyncedTab) {
        let payload = CloseTabPayload(
            browserName: tab.browserName,
            tabID: tab.tabID,
            url: tab.url,
            windowIndex: tab.windowIndex,
            tabIndex: tab.tabIndex
        )
        guard let payloadJSON = Self.encodedPayload(payload) else { return }

        queueCommand(SyncCommand(
            kind: .closeTab,
            targetDeviceID: tab.deviceID,
            sourceDeviceName: deviceName,
            payloadJSON: payloadJSON
        ))
    }

    public func sendDeleteBookmark(bookmark: SyncedBookmarkItem, browserName: String, profileName: String?, targetDeviceID: String) {
        let payload = DeleteBookmarkPayload(
            browserName: browserName,
            profileName: profileName,
            bookmarkID: bookmark.id,
            url: bookmark.url
        )
        guard let payloadJSON = Self.encodedPayload(payload) else { return }

        queueCommand(SyncCommand(
            kind: .deleteBookmark,
            targetDeviceID: targetDeviceID,
            sourceDeviceName: deviceName,
            payloadJSON: payloadJSON
        ))
    }

    /// Moves a bookmark to a different folder — same Mac only (`targetDeviceID`
    /// is the source device; the destination browser/profile must live on
    /// that same device). Runs immediately on the Mac, no approval step.
    public func sendMoveBookmark(
        bookmark: SyncedBookmarkItem,
        sourceBrowserName: String,
        sourceProfileName: String,
        destinationBrowserName: String,
        destinationProfileName: String,
        destinationFolderPath: [String],
        targetDeviceID: String
    ) {
        let payload = MoveBookmarkPayload(
            sourceBrowserName: sourceBrowserName,
            sourceProfileName: sourceProfileName,
            bookmarkID: bookmark.id,
            url: bookmark.url,
            destinationBrowserName: destinationBrowserName,
            destinationProfileName: destinationProfileName,
            destinationFolderPath: destinationFolderPath
        )
        guard let payloadJSON = Self.encodedPayload(payload) else { return }

        queueCommand(SyncCommand(
            kind: .moveBookmark,
            targetDeviceID: targetDeviceID,
            sourceDeviceName: deviceName,
            payloadJSON: payloadJSON
        ))
    }

    /// Saves a brand-new bookmark (from an open tab, etc.) into a chosen folder
    /// on a Mac. Same device scoping as `sendMoveBookmark` — the destination
    /// browser/profile must live on `targetDeviceID`. Runs immediately on the
    /// Mac, no approval step.
    public func sendAddBookmark(
        title: String,
        url: String,
        destinationBrowserName: String,
        destinationProfileName: String,
        destinationFolderPath: [String],
        targetDeviceID: String
    ) {
        let payload = AddBookmarkPayload(
            browserName: destinationBrowserName,
            profileName: destinationProfileName,
            title: title,
            url: url,
            folderPath: destinationFolderPath
        )
        guard let payloadJSON = Self.encodedPayload(payload) else { return }

        queueCommand(SyncCommand(
            kind: .addBookmark,
            targetDeviceID: targetDeviceID,
            sourceDeviceName: deviceName,
            payloadJSON: payloadJSON
        ))
    }

    /// Creates a brand-new bookmark folder or subfolder in a chosen browser/profile
    /// on a Mac. Runs immediately on the Mac, no approval step.
    public func sendCreateFolder(
        name: String,
        parentFolderPath: [String],
        browserName: String,
        profileName: String,
        targetDeviceID: String
    ) {
        let payload = CreateFolderPayload(
            browserName: browserName,
            profileName: profileName,
            folderName: name,
            parentFolderPath: parentFolderPath
        )
        guard let payloadJSON = Self.encodedPayload(payload) else { return }

        queueCommand(SyncCommand(
            kind: .createFolder,
            targetDeviceID: targetDeviceID,
            sourceDeviceName: deviceName,
            payloadJSON: payloadJSON
        ))
    }

    public func sendDeleteHistoryItem(entry: SyncedHistoryEntry, browserName: String, targetDeviceID: String) {
        let payload = DeleteHistoryItemPayload(browserName: browserName, url: entry.url)
        guard let payloadJSON = Self.encodedPayload(payload) else { return }

        queueCommand(SyncCommand(
            kind: .deleteHistoryItem,
            targetDeviceID: targetDeviceID,
            sourceDeviceName: deviceName,
            payloadJSON: payloadJSON
        ))
    }

    nonisolated private static func encodedPayload<Payload: Encodable>(_ payload: Payload) -> String? {
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func queueCommand(_ command: SyncCommand) {
        // Durability first: on disk before CKSyncEngine is told anything, so a
        // suspension or kill mid-send can never lose the user's intent. If that
        // write fails we still attempt the upload — best effort beats nothing —
        // but the user is told it is not guaranteed.
        let isDurable = persistToOutbox(command)
        LocalCache.shared.recordSentCommand(command, delivery: .queuedLocally)
        if !isDurable {
            logger.error("Command \(command.id, privacy: .public) is not durable; it will only arrive if this send succeeds before the app is killed")
        }

        guard let syncEngine else {
            logger.error("Queued command \(command.id, privacy: .public) before the sync engine started; it will be sent on next launch")
            return
        }

        let record = command.toRecord(zoneID: SyncConstants.commandsZoneID)
        pendingRecordsToSave[record.recordID] = record
        syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
        logger.info("Queued outbound command id=\(command.id, privacy: .public) kind=\(command.kind.rawValue, privacy: .public)")
        sendThenFetch()
    }

    @discardableResult
    private func persistToOutbox(_ command: SyncCommand) -> Bool {
        var isDurable = true
        do {
            try commandOutbox.enqueue(command)
        } catch {
            isDurable = false
            logger.error("Failed to persist command \(command.id, privacy: .public) to the durable outbox: \(error.localizedDescription, privacy: .public)")
            let message = "FastTab couldn't save this change on your iPhone, so it may not reach your Mac."
            lastSyncError = message
            syncHealth = .failing(message)
        }
        pendingCommandCount = commandOutbox.pendingCount
        return isDurable
    }

    /// Rebuilds the record bodies for every command CloudKit never confirmed and
    /// re-arms the sync engine for them. Mirrors macOS
    /// `SyncService.restoreCompletedCommandOutbox()`.
    func restorePendingCommandOutbox() {
        guard let syncEngine else { return }
        let commands = commandOutbox.pendingCommands
        pendingCommandCount = commands.count
        guard !commands.isEmpty else { return }

        let alreadyArmed = Self.armedSaveIDs(in: syncEngine.state.pendingRecordZoneChanges)
        let records = commands.map { $0.toRecord(zoneID: SyncConstants.commandsZoneID) }
        for record in records {
            pendingRecordsToSave[record.recordID] = record
        }
        // Re-arming an in-flight change would leave a duplicate pending save
        // with no record body once the original lands, which then shows up as a
        // bogus "no record body" error.
        let toArm = records.filter { !alreadyArmed.contains($0.recordID) }
        guard !toArm.isEmpty else { return }
        syncEngine.state.add(pendingRecordZoneChanges: toArm.map { .saveRecord($0.recordID) })
        logger.info("Restored \(toArm.count, privacy: .public) unconfirmed commands from the durable outbox")
    }

    /// Drops a change the user no longer wants sent. Without this, deleting a
    /// row from the queue only hides it: the durable outbox would still deliver
    /// it to the Mac later.
    public func cancelQueuedCommand(id: String) {
        do {
            try commandOutbox.remove(commandID: id)
        } catch {
            logger.error("Failed to cancel queued command \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        let recordID = CKRecord.ID(recordName: id, zoneID: SyncConstants.commandsZoneID)
        pendingRecordsToSave.removeValue(forKey: recordID)
        syncEngine?.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
        pendingCommandCount = commandOutbox.pendingCount
        LocalCache.shared.removeSentCommand(id: id)
    }

    func confirmUpload(of record: CKRecord) {
        pendingRecordsToSave.removeValue(forKey: record.recordID)
        retainOwnDeviceRecordIfMine(record)
        guard record.recordType == SyncCommand.recordType else { return }

        let commandID = record.recordID.recordName
        // Clear the durable row first. A row that outlives its confirmation is
        // re-uploaded on the next launch, and the Mac can act on it a second
        // time; losing the local "uploaded" marker instead is cosmetic, and it
        // self-corrects as soon as the Mac writes any status back.
        do {
            try commandOutbox.remove(commandID: commandID)
        } catch {
            logger.error("Failed to clear confirmed command \(commandID, privacy: .public) from the outbox: \(error.localizedDescription, privacy: .public)")
        }
        pendingCommandCount = commandOutbox.pendingCount
        LocalCache.shared.markCommandUploaded(id: commandID)
    }

    /// A save CloudKit will never accept must leave the outbox, otherwise the
    /// "changes waiting" count sticks at a number the user can never clear.
    func abandonUnsendableCommand(_ record: CKRecord, error: Error) {
        guard record.recordType == SyncCommand.recordType else { return }
        let commandID = record.recordID.recordName
        do {
            try commandOutbox.remove(commandID: commandID)
        } catch {
            logger.error("Failed to drop unsendable command \(commandID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        pendingRecordsToSave.removeValue(forKey: record.recordID)
        pendingCommandCount = commandOutbox.pendingCount
        // Terminal, but never delivered: leave the delivery step alone and mark
        // the command itself refused so the UI stops showing it as in transit.
        LocalCache.shared.markCommandUndeliverable(
            id: commandID,
            reason: SyncHealthMapping.message(forFailure: error)
        )
        logger.error("Abandoned command \(commandID, privacy: .public); CloudKit rejected it permanently: \(error.localizedDescription, privacy: .public)")
    }

    // MARK: - Pure helpers

    /// iOS writes two record types: `SyncCommand`s and its own `SyncedDevice`
    /// heartbeat. A lost optimistic-concurrency race just means re-applying our
    /// fields onto the server copy. Same shape as macOS
    /// `SyncService.recordForRetry`.
    nonisolated static func recordForRetry(
        intendedRecord: CKRecord,
        error: Error
    ) -> CKRecord? {
        guard let cloudKitError = error as? CKError else { return nil }
        if cloudKitError.code == .unknownItem {
            // The cached server copy was deleted: re-insert the heartbeat
            // fresh. Commands are never resurrected — a missing one was cleared.
            guard let intendedDevice = SyncedDevice(from: intendedRecord) else { return nil }
            return intendedDevice.toRecord(zoneID: intendedRecord.recordID.zoneID)
        }
        guard cloudKitError.code == .serverRecordChanged,
              let serverRecord = cloudKitError.serverRecord,
              serverRecord.recordID == intendedRecord.recordID,
              serverRecord.recordType == intendedRecord.recordType else {
            return nil
        }
        switch intendedRecord.recordType {
        case SyncCommand.recordType:
            return SyncCommand(from: intendedRecord)?.applying(to: serverRecord)
        case SyncedDevice.recordType:
            return SyncedDevice(from: intendedRecord)?.applying(to: serverRecord)
        default:
            return nil
        }
    }

    /// Pending saves the record provider cannot satisfy. Returning `nil` from
    /// the provider makes `CKSyncEngine` drop the change with no error at all,
    /// so these are surfaced and cleaned up explicitly instead.
    nonisolated static func unsatisfiablePendingSaveIDs(
        pendingChanges: [CKSyncEngine.PendingRecordZoneChange],
        availableRecords: [CKRecord.ID: CKRecord]
    ) -> [CKRecord.ID] {
        pendingChanges.compactMap { change in
            guard case .saveRecord(let recordID) = change else { return nil }
            return availableRecords[recordID] == nil ? recordID : nil
        }
    }

    nonisolated static func armedSaveIDs(
        in pendingChanges: [CKSyncEngine.PendingRecordZoneChange]
    ) -> Set<CKRecord.ID> {
        Set(pendingChanges.compactMap { change in
            guard case .saveRecord(let recordID) = change else { return nil }
            return recordID
        })
    }

    nonisolated static func deliverablePendingChanges(
        pendingChanges: [CKSyncEngine.PendingRecordZoneChange],
        excludingSaveIDs excluded: Set<CKRecord.ID>
    ) -> [CKSyncEngine.PendingRecordZoneChange] {
        guard !excluded.isEmpty else { return pendingChanges }
        return pendingChanges.filter { change in
            guard case .saveRecord(let recordID) = change else { return true }
            return !excluded.contains(recordID)
        }
    }
}
