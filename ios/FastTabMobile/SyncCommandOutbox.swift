import Foundation
import OSLog
import FastTabSync

/// Durable record of the commands this phone has queued for a Mac but that
/// CloudKit has not confirmed yet.
///
/// `CKSyncEngine` persists the *fact* that a change is pending, but asks the
/// delegate's record provider for the record's contents at send time. When iOS
/// suspends and kills the app mid-send, an in-memory-only provider has nothing
/// to hand back on the next launch and the change is dropped silently — the
/// user's "close this tab" simply never happens.
///
/// Storing the `SyncCommand` domain values (records are re-derivable via
/// `toRecord(zoneID:)`) makes that survivable. Mirrors `SyncCommandJournal` on
/// macOS, which solves the same problem for outbound command *responses*.
public final class SyncCommandOutbox {
    /// Guards against unbounded growth when a phone can never reach CloudKit
    /// (permanently signed out, for instance). Oldest intents are shed first.
    ///
    /// `LocalCache` never evicts a command that is still queued here, so every
    /// entry always has a visible row the user can inspect or cancel.
    public static let maxEntries = 100

    public static let defaultFileName = "ios_command_outbox.json"

    private struct PersistedState: Codable {
        var pending: [String: SyncCommand] = [:]
    }

    private let fileURL: URL
    private var state: PersistedState
    private let logger = Logger(subsystem: "app.theindie.FastTab", category: "SyncCommandOutbox")

    public init(fileURL: URL = AppGroupContainer.fileURL(forFileNamed: SyncCommandOutbox.defaultFileName)) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(PersistedState.self, from: data) {
            self.state = decoded
        } else {
            self.state = PersistedState()
        }
    }

    /// Oldest first, so a backlog is retried in the order the user created it.
    public var pendingCommands: [SyncCommand] {
        state.pending.values.sorted { $0.issuedAt < $1.issuedAt }
    }

    /// How many changes are still waiting to reach a Mac.
    public var pendingCount: Int { state.pending.count }

    /// Must be called *before* the sync engine is told about the change.
    public func enqueue(_ command: SyncCommand) throws {
        var nextState = state
        nextState.pending[command.id] = command
        let shed = Self.identifiersToShed(
            from: nextState.pending,
            maxEntries: Self.maxEntries,
            keeping: command.id
        )
        for identifier in shed {
            nextState.pending.removeValue(forKey: identifier)
        }
        try persist(nextState)
        state = nextState
        if !shed.isEmpty {
            logger.error("Outbox exceeded \(Self.maxEntries, privacy: .public) entries; dropped \(shed.count, privacy: .public) oldest unsent commands")
        }
    }

    /// Called only once CloudKit has confirmed the write, or when the write was
    /// rejected in a way that will never succeed.
    public func remove(commandID: String) throws {
        guard state.pending[commandID] != nil else { return }
        var nextState = state
        nextState.pending.removeValue(forKey: commandID)
        try persist(nextState)
        state = nextState
    }

    public func contains(commandID: String) -> Bool {
        state.pending[commandID] != nil
    }

    /// Oldest entries beyond the cap. Pure, so the shedding rule is inspectable.
    nonisolated static func identifiersToShed(
        from pending: [String: SyncCommand],
        maxEntries: Int,
        keeping protectedID: String? = nil
    ) -> [String] {
        guard pending.count > maxEntries else { return [] }
        // The command being enqueued is never the one shed, however odd its
        // timestamp — dropping it would report success for a lost change.
        let sheddable = pending.values
            .filter { $0.id != protectedID }
            .sorted { $0.issuedAt < $1.issuedAt }
        return sheddable.prefix(pending.count - maxEntries).map(\.id)
    }

    private func persist(_ state: PersistedState) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(state)
        try data.write(to: fileURL, options: .atomic)
    }
}
