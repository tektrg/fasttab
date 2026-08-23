import Foundation
import OSLog
import FastTabSync

public struct CachedSyncState: Codable, Sendable {
    public var devices: [SyncedDevice] = []
    public var tabs: [SyncedTab] = []
    public var bookmarkBlobs: [SyncedBookmarkBlob] = []
    public var historySlices: [SyncedHistorySlice] = []
    public var sentCommands: [SyncCommand] = []
    public var lastSyncedAt: Date?
    /// How far each sent command has physically travelled, keyed by command id.
    ///
    /// Kept beside `sentCommands` rather than inside `SyncCommand` because that
    /// type is the CloudKit wire format shared with macOS: delivery is a purely
    /// local fact about *this* phone's upload, not something the Mac reports.
    public var commandDeliveries: [String: SyncCommandDelivery] = [:]

    public init(
        devices: [SyncedDevice] = [],
        tabs: [SyncedTab] = [],
        bookmarkBlobs: [SyncedBookmarkBlob] = [],
        historySlices: [SyncedHistorySlice] = [],
        sentCommands: [SyncCommand] = [],
        lastSyncedAt: Date? = nil,
        commandDeliveries: [String: SyncCommandDelivery] = [:]
    ) {
        self.devices = devices
        self.tabs = tabs
        self.bookmarkBlobs = bookmarkBlobs
        self.historySlices = historySlices
        self.sentCommands = sentCommands
        self.lastSyncedAt = lastSyncedAt
        self.commandDeliveries = commandDeliveries
    }

    /// Hand-written so a cache file written by an *older* build — which has no
    /// `commandDeliveries` key, and may lack any future key — still decodes
    /// instead of wiping the user's cached tabs. Swift's synthesised decoder
    /// ignores default values and would throw on the missing key.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.devices = try container.decodeIfPresent([SyncedDevice].self, forKey: .devices) ?? []
        self.tabs = try container.decodeIfPresent([SyncedTab].self, forKey: .tabs) ?? []
        self.bookmarkBlobs = try container.decodeIfPresent([SyncedBookmarkBlob].self, forKey: .bookmarkBlobs) ?? []
        self.historySlices = try container.decodeIfPresent([SyncedHistorySlice].self, forKey: .historySlices) ?? []
        self.sentCommands = try container.decodeIfPresent([SyncCommand].self, forKey: .sentCommands) ?? []
        self.lastSyncedAt = try container.decodeIfPresent(Date.self, forKey: .lastSyncedAt)
        self.commandDeliveries = try container.decodeIfPresent([String: SyncCommandDelivery].self, forKey: .commandDeliveries) ?? [:]
    }
}

@MainActor
public final class LocalCache: ObservableObject {
    public static let shared = LocalCache()

    @Published public private(set) var state: CachedSyncState = CachedSyncState()

    private let logger = Logger(subsystem: "app.theindie.FastTab", category: "LocalCache")
    private let fileURL: URL

    /// Coalesces disk writes. A single fetch can call `updateTab` hundreds of
    /// times; writing the whole JSON blob per tab made a 200-tab sync do 200
    /// full encodes. Mutations now mark the cache dirty and one write happens at
    /// the end of the run-loop turn. Safe because this file is a *cache* — the
    /// durable outbox is written synchronously and separately.
    private var pendingSaveTask: Task<Void, Never>?

    private static let cacheFileName = "sync_cache.json"

    /// How many *delivered* sent commands stay visible in the history list.
    /// Commands still waiting to leave the phone are never evicted, however many
    /// there are, so the queue badge always has a row to point at.
    static let maxRememberedCommands = 100

    public init(customFileURL: URL? = nil) {
        self.fileURL = customFileURL ?? AppGroupContainer.fileURL(forFileNamed: Self.cacheFileName)
        loadFromDisk()
    }

    public func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            self.state = try JSONDecoder().decode(CachedSyncState.self, from: data)
            logger.info("Loaded cache from disk: \(self.state.devices.count) devices, \(self.state.tabs.count) tabs, \(self.state.bookmarkBlobs.count) bookmark blobs, \(self.state.historySlices.count) history slices")
        } catch {
            logger.error("Failed to load local cache: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func saveToDisk() {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        do {
            let dir = fileURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(state)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Failed to save local cache: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Writes immediately if anything is still buffered. Call before the app is
    /// about to lose the foreground.
    public func flushPendingSave() {
        guard pendingSaveTask != nil else { return }
        saveToDisk()
    }

    private func scheduleSave() {
        guard pendingSaveTask == nil else { return }
        pendingSaveTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            self.saveToDisk()
        }
    }

    // MARK: - Mutations

    public func updateDevice(_ device: SyncedDevice) {
        if let idx = state.devices.firstIndex(where: { $0.id == device.id }) {
            state.devices[idx] = device
        } else {
            state.devices.append(device)
        }
        state.lastSyncedAt = Date()
        scheduleSave()
    }

    public func removeDevice(id: String) {
        state.devices.removeAll { $0.id == id }
        state.tabs.removeAll { $0.deviceID == id }
        state.bookmarkBlobs.removeAll { $0.deviceID == id }
        state.historySlices.removeAll { $0.deviceID == id }
        scheduleSave()
    }

    public func updateTab(_ tab: SyncedTab) {
        if let idx = state.tabs.firstIndex(where: { $0.id == tab.id }) {
            state.tabs[idx] = tab
        } else {
            state.tabs.append(tab)
        }
        state.lastSyncedAt = Date()
        scheduleSave()
    }

    public func removeTab(id: String) {
        state.tabs.removeAll { $0.id == id }
        scheduleSave()
    }

    public func updateBookmarkBlob(_ blob: SyncedBookmarkBlob) {
        if let idx = state.bookmarkBlobs.firstIndex(where: { $0.id == blob.id }) {
            state.bookmarkBlobs[idx] = blob
        } else {
            state.bookmarkBlobs.append(blob)
        }
        state.lastSyncedAt = Date()
        scheduleSave()
    }

    public func removeBookmarkBlob(id: String) {
        state.bookmarkBlobs.removeAll { $0.id == id }
        scheduleSave()
    }

    public func updateHistorySlice(_ slice: SyncedHistorySlice) {
        if let idx = state.historySlices.firstIndex(where: { $0.id == slice.id }) {
            state.historySlices[idx] = slice
        } else {
            state.historySlices.append(slice)
        }
        state.lastSyncedAt = Date()
        scheduleSave()
    }

    public func removeHistorySlice(id: String) {
        state.historySlices.removeAll { $0.id == id }
        scheduleSave()
    }

    // MARK: - Sent commands

    public func recordSentCommand(
        _ command: SyncCommand,
        delivery: SyncCommandDelivery = .queuedLocally
    ) {
        if let idx = state.sentCommands.firstIndex(where: { $0.id == command.id }) {
            state.sentCommands[idx] = command
        } else {
            state.sentCommands.insert(command, at: 0)
        }
        state.sentCommands = Self.trimmed(
            state.sentCommands,
            deliveries: state.commandDeliveries,
            limit: Self.maxRememberedCommands
        )
        advanceDelivery(to: delivery, forCommandID: command.id)
        discardOrphanedDeliveries()
        scheduleSave()
    }

    /// CloudKit confirmed the upload; the change is now the Mac's problem.
    public func markCommandUploaded(id: String) {
        advanceDelivery(to: .uploaded, forCommandID: id)
        scheduleSave()
    }

    /// The upload was permanently rejected. The command is finished, but it
    /// never travelled — so the delivery step stays where it was.
    public func markCommandUndeliverable(id: String, reason: String) {
        guard let idx = state.sentCommands.firstIndex(where: { $0.id == id }) else { return }
        state.sentCommands[idx].status = .refused
        state.sentCommands[idx].statusReason = reason
        state.sentCommands[idx].completedAt = Date()
        scheduleSave()
    }

    public func updateCommandStatus(id: String, status: SyncCommandStatus, reason: String?, completedAt: Date?) {
        guard let idx = state.sentCommands.firstIndex(where: { $0.id == id }) else { return }
        state.sentCommands[idx].status = status
        state.sentCommands[idx].statusReason = reason
        state.sentCommands[idx].completedAt = completedAt
        // A status coming back from the Mac proves the upload landed, so this is
        // also the moment delivery reaches its end state.
        advanceDelivery(to: Self.isTerminal(status) ? .acknowledged : .uploaded, forCommandID: id)
        scheduleSave()
    }

    public func removeSentCommand(id: String) {
        state.sentCommands.removeAll { $0.id == id }
        discardOrphanedDeliveries()
        scheduleSave()
    }

    public func clearAllSentCommands() {
        state.sentCommands.removeAll()
        state.commandDeliveries.removeAll()
        scheduleSave()
    }

    /// How far a sent command has actually travelled. Lets the UI separate
    /// "still stuck on this phone" (the user's network) from "uploaded, waiting
    /// on the Mac" (nothing the user can do here).
    public func delivery(forCommandID id: String) -> SyncCommandDelivery {
        state.commandDeliveries[id] ?? .queuedLocally
    }

    private func advanceDelivery(to delivery: SyncCommandDelivery, forCommandID id: String) {
        // Only for commands still in the list, otherwise the map accumulates
        // rows for commands nothing can ever display.
        guard state.sentCommands.contains(where: { $0.id == id }) else { return }
        state.commandDeliveries[id] = Self.advancedDelivery(
            from: state.commandDeliveries[id],
            to: delivery
        )
    }

    private func discardOrphanedDeliveries() {
        guard !state.commandDeliveries.isEmpty else { return }
        let liveCommandIDs = Set(state.sentCommands.map(\.id))
        state.commandDeliveries = state.commandDeliveries.filter { liveCommandIDs.contains($0.key) }
    }

    /// Newest-first trim that protects anything still queued on this phone: a
    /// command the user can neither see nor cancel would strand the "changes
    /// waiting" badge. Commands already given up on (a terminal status) are
    /// evictable like any other.
    nonisolated static func trimmed(
        _ commands: [SyncCommand],
        deliveries: [String: SyncCommandDelivery],
        limit: Int
    ) -> [SyncCommand] {
        guard commands.count > limit else { return commands }
        var keptEvictableCount = 0
        return commands.filter { command in
            let isStillOnThisPhone = (deliveries[command.id] ?? .queuedLocally) == .queuedLocally
                && !isTerminal(command.status)
            if isStillOnThisPhone { return true }
            keptEvictableCount += 1
            return keptEvictableCount <= limit
        }
    }

    // MARK: - Pure delivery rules

    /// Delivery only ever moves forward. A late CloudKit callback must not drag
    /// a command the Mac already acknowledged back to "waiting".
    nonisolated static func advancedDelivery(
        from current: SyncCommandDelivery?,
        to next: SyncCommandDelivery
    ) -> SyncCommandDelivery {
        guard let current else { return next }
        return progressRank(of: next) > progressRank(of: current) ? next : current
    }

    nonisolated static func progressRank(of delivery: SyncCommandDelivery) -> Int {
        switch delivery {
        case .queuedLocally: return 0
        case .uploaded: return 1
        case .acknowledged: return 2
        }
    }

    /// Statuses the Mac will never move away from. `needsApproval` is excluded:
    /// the Mac has seen the command but is still waiting on a human.
    nonisolated static func isTerminal(_ status: SyncCommandStatus) -> Bool {
        switch status {
        case .pending, .inProgress, .needsApproval:
            return false
        case .done, .notFound, .expired, .refused:
            return true
        }
    }
}
