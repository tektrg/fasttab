import Foundation
import CloudKit
import OSLog
import FastTabSync

@MainActor
final class SyncService: NSObject, ObservableObject {
    static let shared = SyncService()

    private let logger = Logger(subsystem: "com.trungluong.FastTab", category: "SyncService")

    let deviceID: String
    let deviceName: String
    let deviceModel: String

    private var syncEngine: CKSyncEngine?
    private lazy var syncSendCoordinator = SyncSendCoordinator { [weak self] in
        await self?.performPendingChangesSend()
    }
    private let container: CKContainer
    private let database: CKDatabase
    private let stateFileURL: URL
    private let commandJournal: SyncCommandJournal

    // In-memory cache of records to be supplied to CKSyncEngine recordProvider
    private var pendingRecordsToSave: [CKRecord.ID: CKRecord] = [:]

    // Track previously published state to compute diffs
    private var lastPublishedTabIDs: Set<CKRecord.ID> = []
    /// Content fingerprint of the last published tab snapshot. When the new
    /// snapshot hashes to the same value (same set of URLs/titles/states), the
    /// entire CKSyncEngine push is skipped — no CKRecords are built and no
    /// network traffic is generated.
    private var lastPublishedTabContentHash: String = ""
    private var lastPublishedBookmarkHashes: [String: String] = [:]
    private var lastPublishedHistoryHashes: [String: String] = [:]

    private var tabDebounceTask: Task<Void, Never>?
    private var syncPollTimer: Timer?
    private var isInitialized = false

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
        self.stateFileURL = fastTabDir.appendingPathComponent("sync_state.dat")
        self.commandJournal = SyncCommandJournal(
            fileURL: fastTabDir.appendingPathComponent("sync_command_journal.json")
        )

        super.init()

        self.lastPublishedTabIDs = Self.loadPublishedTabRecordIDs(deviceID: deviceID)

        logger.info("SyncService initialized. deviceID=\(self.deviceID, privacy: .public) name='\(self.deviceName, privacy: .public)' model='\(self.deviceModel, privacy: .public)'")
    }

    func start() {
        guard !isInitialized else { return }
        isInitialized = true

        setupSyncEngine()
        publishDevice()
        fetchLatestChanges()
        Task { @MainActor in
            // AppState owns BrowserTabService.shared and is still initializing here.
            // Yield before resolving it to avoid recursively entering AppState.shared.
            await Task.yield()
            BrowserTabService.shared.refreshAuthoritativeLiveTabsAndPublish()
        }
        startSyncPollTimer()
    }

    private func startSyncPollTimer() {
        syncPollTimer?.invalidate()
        syncPollTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.fetchLatestChanges()
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
        guard let syncEngine else { return }

        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let device = SyncedDevice(
            id: deviceID,
            name: deviceName,
            modelName: deviceModel,
            lastSeenAt: Date(),
            appVersion: appVersion
        )

        let record = device.toRecord(zoneID: SyncConstants.stateZoneID)
        pendingRecordsToSave[record.recordID] = record

        syncEngine.state.add(pendingRecordZoneChanges: [
            .saveRecord(record.recordID)
        ])
        logger.info("Queued device record publish for \(self.deviceName, privacy: .public)")
        sendPendingChanges()
    }

    // MARK: - Live Tabs Publishing

    func updateLiveTabs(_ tabs: [BrowserSearchResult]) {
        tabDebounceTask?.cancel()
        tabDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5s debounce
            guard !Task.isCancelled, let self else { return }
            self.publishLiveTabsNow(tabs)
        }
    }

    func publishLiveTabsNow(_ tabs: [BrowserSearchResult]) {
        guard let syncEngine else { return }

        // Filter out incognito / private browsing tabs
        let publicTabs = tabs.filter { !Self.isIncognitoTab($0) }

        // Content-hash check: skip the entire CKRecord build + CloudKit push
        // when the set of tabs hasn't changed since the last publish. Matches
        // the pattern used by updateBookmarks/updateHistory. The hash captures
        // tab identity (browser, URL, title, tabID) — if any tab is opened,
        // closed, navigated, or renamed, the hash changes and we re-sync.
        let contentFingerprint = Self.tabContentFingerprint(publicTabs)
        guard contentFingerprint != lastPublishedTabContentHash else {
            logger.info("Live tabs sync skipped (content unchanged). tabCount=\(publicTabs.count)")
            return
        }

        var currentRecords: [CKRecord] = []
        var currentRecordIDs: Set<CKRecord.ID> = []

        for (index, tab) in publicTabs.enumerated() {
            let tabSlug: String
            if let tabID = tab.tabID {
                tabSlug = "tab_\(tabID)"
            } else {
                tabSlug = "win\(tab.windowIndex ?? 0)_idx\(tab.tabIndex ?? index)"
            }
            let rawRecordName = "\(deviceID)_\(tab.browserName)_\(tabSlug)"
            let recordName = Self.sanitizeRecordName(rawRecordName)

            let syncedTab = SyncedTab(
                id: recordName,
                deviceID: deviceID,
                browserName: tab.browserName,
                title: tab.title,
                url: tab.url,
                timestamp: tab.timestamp,
                windowIndex: tab.windowIndex,
                tabIndex: tab.tabIndex,
                windowName: tab.windowName,
                tabID: tab.tabID,
                isAudible: tab.isAudible,
                isMuted: tab.isMuted,
                isPinned: tab.isPinned,
                isDiscarded: tab.isDiscarded,
                tabGroupTitle: tab.tabGroupTitle,
                profileName: tab.profileName
            )

            let record = syncedTab.toRecord(zoneID: SyncConstants.stateZoneID)
            currentRecords.append(record)
            currentRecordIDs.insert(record.recordID)
            pendingRecordsToSave[record.recordID] = record
        }

        // Calculate diff: records to save vs records to delete
        let recordIDsToDelete = Self.tabRecordIDsToDelete(
            previouslyPublished: lastPublishedTabIDs,
            currentlyPublished: currentRecordIDs
        )

        var pendingChanges: [CKSyncEngine.PendingRecordZoneChange] = []
        for record in currentRecords {
            pendingChanges.append(.saveRecord(record.recordID))
        }
        for deleteID in recordIDsToDelete {
            pendingChanges.append(.deleteRecord(deleteID))
            pendingRecordsToSave.removeValue(forKey: deleteID)
        }

        let durableTabRecordLedger = Self.tabRecordLedgerAfterPublishing(
            remotelyKnown: lastPublishedTabIDs,
            currentlyPublished: currentRecordIDs
        )
        lastPublishedTabIDs = durableTabRecordLedger
        Self.persistPublishedTabRecordIDs(durableTabRecordLedger, deviceID: deviceID)
        lastPublishedTabContentHash = contentFingerprint

        if !pendingChanges.isEmpty {
            syncEngine.state.add(pendingRecordZoneChanges: pendingChanges)
            logger.info("Live tabs sync queued: \(currentRecords.count) to save, \(recordIDsToDelete.count) to delete")
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

            if let record = blob.toRecord(zoneID: SyncConstants.stateZoneID) {
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

            if let record = slice.toRecord(zoneID: SyncConstants.stateZoneID) {
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

    // MARK: - Command Response Publishing

    func pushCommandResult(_ command: SyncCommand) {
        do {
            try commandJournal.storeCompletedResponse(command)
        } catch {
            logger.error("Failed to persist command response \(command.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        guard let syncEngine else { return }

        let record = command.toRecord(zoneID: SyncConstants.commandsZoneID)
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
        } catch {
            logger.error("CKSyncEngine sendChanges error: \(error.localizedDescription, privacy: .public)")
        }
    }

    func fetchLatestChanges() {
        guard let syncEngine else { return }
        Task {
            do {
                try await syncEngine.fetchChanges()
                self.logger.info("Triggered CKSyncEngine fetchChanges")
            } catch {
                self.logger.error("CKSyncEngine fetchChanges error: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Helpers

    nonisolated static func isIncognitoTab(_ tab: BrowserSearchResult) -> Bool {
        let lowerWindow = (tab.windowName ?? "").lowercased()
        if lowerWindow.contains("incognito") ||
           lowerWindow.contains("private") ||
           lowerWindow.contains("inprivate") ||
           lowerWindow.contains("tor") {
            return true
        }
        let lowerProfile = (tab.profileName ?? "").lowercased()
        if lowerProfile.contains("incognito") || lowerProfile.contains("private") {
            return true
        }
        return false
    }

    nonisolated static func sanitizeRecordName(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
            .map(String.init)
            .joined()
    }

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
        lastPublishedTabIDs.removeAll()
        Self.persistPublishedTabRecordIDs([], deviceID: deviceID)
        lastPublishedTabContentHash = ""
        lastPublishedBookmarkHashes.removeAll()
        lastPublishedHistoryHashes.removeAll()
        pendingRecordsToSave.removeAll()
    }

    nonisolated static func tabRecordIDsToDelete(
        previouslyPublished: Set<CKRecord.ID>,
        currentlyPublished: Set<CKRecord.ID>
    ) -> Set<CKRecord.ID> {
        previouslyPublished.subtracting(currentlyPublished)
    }

    nonisolated static func tabRecordLedgerAfterPublishing(
        remotelyKnown: Set<CKRecord.ID>,
        currentlyPublished: Set<CKRecord.ID>
    ) -> Set<CKRecord.ID> {
        remotelyKnown.union(currentlyPublished)
    }

    nonisolated static func tabRecordLedgerAfterAcknowledgingDeletions(
        remotelyKnown: Set<CKRecord.ID>,
        deletedRecordIDs: Set<CKRecord.ID>
    ) -> Set<CKRecord.ID> {
        remotelyKnown.subtracting(deletedRecordIDs)
    }

    nonisolated static func shouldProcessIncomingCommand(_ command: SyncCommand) -> Bool {
        command.status == .pending
    }

    nonisolated static func loadPublishedTabRecordIDs(
        deviceID: String,
        defaults: UserDefaults = .standard
    ) -> Set<CKRecord.ID> {
        let recordNames = defaults.stringArray(forKey: publishedTabRecordNamesDefaultsKey(deviceID: deviceID)) ?? []
        return Set(recordNames.map {
            CKRecord.ID(recordName: $0, zoneID: SyncConstants.stateZoneID)
        })
    }

    nonisolated static func persistPublishedTabRecordIDs(
        _ recordIDs: Set<CKRecord.ID>,
        deviceID: String,
        defaults: UserDefaults = .standard
    ) {
        let key = publishedTabRecordNamesDefaultsKey(deviceID: deviceID)
        guard !recordIDs.isEmpty else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(recordIDs.map(\.recordName).sorted(), forKey: key)
    }

    nonisolated private static func publishedTabRecordNamesDefaultsKey(deviceID: String) -> String {
        "FastTab.PublishedTabRecordNames.\(deviceID)"
    }

    /// Lightweight content fingerprint for a set of tabs. Changes whenever a
    /// tab is opened, closed, navigated, or renamed. Uses `.hashValue` on a
    /// concatenated identity string — fast, no crypto dependency, sufficient
    /// for in-memory same-process diffing (not persisted across launches).
    nonisolated static func tabContentFingerprint(_ tabs: [BrowserSearchResult]) -> String {
        // Sort by a stable key so reordering alone doesn't trigger a re-sync.
        var hasher = Hasher()
        hasher.combine(tabs.count)
        let sorted = tabs.map { "\($0.browserName)|\($0.url)|\($0.title)|\($0.tabID ?? -1)" }.sorted()
        for entry in sorted {
            hasher.combine(entry)
        }
        return String(hasher.finalize())
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
                    if record.recordType == SyncCommand.recordType {
                        if let command = SyncCommand(from: record) {
                            self.handleIncomingCommand(command)
                        }
                    }
                }

            case .sentRecordZoneChanges(let sentChanges):
                for saved in sentChanges.savedRecords {
                    self.pendingRecordsToSave.removeValue(forKey: saved.recordID)
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
                    self.lastPublishedTabIDs = Self.tabRecordLedgerAfterAcknowledgingDeletions(
                        remotelyKnown: self.lastPublishedTabIDs,
                        deletedRecordIDs: Set(sentChanges.deletedRecordIDs)
                    )
                    Self.persistPublishedTabRecordIDs(
                        self.lastPublishedTabIDs,
                        deviceID: self.deviceID
                    )
                }
                for failedSave in sentChanges.failedRecordSaves {
                    self.logger.error("Failed to save record \(failedSave.record.recordID.recordName, privacy: .public): \(failedSave.error.localizedDescription, privacy: .public)")
                }
                for (recordID, error) in sentChanges.failedRecordDeletes {
                    syncEngine.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
                    self.logger.error("Failed to delete record \(recordID.recordName, privacy: .public); queued retry: \(error.localizedDescription, privacy: .public)")
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

        return await CKSyncEngine.RecordZoneChangeBatch(
            pendingChanges: pendingChanges,
            recordProvider: { recordID in
                records[recordID]
            }
        )
    }

    private func handleIncomingCommand(_ command: SyncCommand) {
        guard Self.shouldProcessIncomingCommand(command) else { return }

        // Check if the command targets this Mac (or is broadcast)
        guard command.targetDeviceID == deviceID || command.targetDeviceID.isEmpty || command.targetDeviceID == "*" else {
            return
        }

        // Check expiration
        if command.expiresAt <= Date() {
            var expiredCmd = command
            expiredCmd.status = .expired
            expiredCmd.statusReason = "Command expired before processing"
            expiredCmd.completedAt = Date()
            pushCommandResult(expiredCmd)
            return
        }

        switch command.kind {
        case .openOnMac:
            SentLinkInbox.shared.receive(command: command)
        case .closeTab:
            switch commandJournal.decision(for: command) {
            case .execute:
                handleCloseTabCommand(command, reconcilingExecution: false)
            case .reconcileExecuting:
                handleCloseTabCommand(command, reconcilingExecution: true)
            case .resendCompleted(let response):
                pushCommandResult(response)
            }
        case .deleteBookmark, .deleteHistoryItem:
            handleDeleteCommand(command)
        }
    }

    private func handleCloseTabCommand(
        _ command: SyncCommand,
        reconcilingExecution: Bool
    ) {
        guard let data = command.payloadJSON.data(using: .utf8),
              let payload = try? JSONDecoder().decode(CloseTabPayload.self, from: data) else {
            var failedCmd = command
            failedCmd.status = .refused
            failedCmd.statusReason = "Invalid close tab payload"
            failedCmd.completedAt = Date()
            pushCommandResult(failedCmd)
            return
        }

        let dummyResult = BrowserSearchResult(
            title: payload.url,
            url: payload.url,
            browserName: payload.browserName,
            type: .tab,
            timestamp: Date(),
            windowIndex: payload.windowIndex,
            tabIndex: payload.tabIndex,
            tabID: payload.tabID
        )

        let backend = BrowserTabService.shared.backend(for: payload.browserName)
        guard let backend else {
            var notFoundCmd = command
            notFoundCmd.status = .notFound
            notFoundCmd.statusReason = "Browser \(payload.browserName) is not available"
            notFoundCmd.completedAt = Date()
            pushCommandResult(notFoundCmd)
            return
        }

        if reconcilingExecution,
           !BrowserTabService.shared.remoteCloseTargetExists(payload) {
            var completedCmd = command
            completedCmd.status = .done
            completedCmd.statusReason = "Tab already absent after interrupted close"
            completedCmd.completedAt = Date()
            BrowserTabService.shared.refreshAuthoritativeLiveTabsAndPublish()
            pushCommandResult(completedCmd)
            return
        }

        if !reconcilingExecution {
            do {
                try commandJournal.markExecuting(command)
            } catch {
                logger.error("Failed to persist executing command \(command.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return
            }
        }

        // Execute tab close with strict safety (allowPositionalFallback: false)
        let result = backend.closeTabWithResult(dummyResult, allowPositionalFallback: false)
        var responseCmd = command
        responseCmd.completedAt = Date()

        switch result {
        case .closed:
            responseCmd.status = .done
            responseCmd.statusReason = "Tab closed on Mac"
            logger.info("Successfully closed tab remotely: url=\(payload.url, privacy: .public)")
            BrowserTabService.shared.recordClosedTabFromRemote(browserName: payload.browserName, url: payload.url, tabID: payload.tabID)
        case .notFound:
            responseCmd.status = .notFound
            responseCmd.statusReason = "Tab not found or browser not running"
            logger.info("Remote close tab not found: url=\(payload.url, privacy: .public)")
        case .refused(let reason):
            responseCmd.status = .refused
            responseCmd.statusReason = reason
            logger.info("Remote close tab refused: \(reason, privacy: .public)")
        }

        pushCommandResult(responseCmd)
    }

    private func handleDeleteCommand(_ command: SyncCommand) {
        if let item = PendingApprovalStore.shared.add(command: command) {
            var responseCmd = command
            responseCmd.status = .needsApproval
            responseCmd.statusReason = "Queued for Mac-side approval"
            pushCommandResult(responseCmd)
            logger.info("Queued delete command id=\(command.id, privacy: .public) as pending approval id=\(item.id, privacy: .public)")
        } else {
            var responseCmd = command
            responseCmd.status = .refused
            responseCmd.statusReason = "Could not queue deletion"
            responseCmd.completedAt = Date()
            pushCommandResult(responseCmd)
        }
    }
}
