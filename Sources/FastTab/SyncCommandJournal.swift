import Foundation
import FastTabSync

enum SyncCommandDuplicateDecision: Equatable {
    case execute
    case reconcileExecuting(SyncCommand)
    case resendCompleted(SyncCommand)
}

final class SyncCommandJournal {
    /// Hard ceiling on remembered already-answered commands.
    ///
    /// Purely a backstop against a peer that stamps absurd expiry dates: the
    /// real bound is each command's own `expiresAt` (see
    /// `retainedSettledResponses`). At roughly half a kilobyte of JSON per
    /// entry this caps the ledger near 256 KB, small enough to rewrite
    /// atomically on every acknowledgement without the write cost mattering.
    static let settledResponseCountCap = 512

    private struct PersistedState: Codable {
        var executing: [String: SyncCommand] = [:]
        var completed: [String: SyncCommand] = [:]
        /// Commands whose answer CloudKit has already confirmed.
        ///
        /// This is the anti-replay ledger, and it exists because the phone's
        /// outbox is at-least-once: a phone killed before it saw its own save
        /// confirmation re-uploads the command on next launch, re-derived from
        /// stored values and therefore back at `.pending`. Without a memory
        /// that outlives the acknowledgement, that re-upload looks brand new
        /// and the Mac closes a second tab / re-raises a dismissed approval.
        var settled: [String: SyncCommand] = [:]

        init() {}

        private enum CodingKeys: String, CodingKey {
            case executing
            case completed
            case settled
        }

        /// Decoded key-by-key on purpose. A journal written by a build that
        /// predates `settled` has no such key, and Swift's synthesised
        /// `Decodable` throws on a missing key even when the property has a
        /// default — which would make every upgrading Mac treat its journal as
        /// corrupt and discard in-flight responses exactly once.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            executing = try container.decodeIfPresent([String: SyncCommand].self, forKey: .executing) ?? [:]
            completed = try container.decodeIfPresent([String: SyncCommand].self, forKey: .completed) ?? [:]
            settled = try container.decodeIfPresent([String: SyncCommand].self, forKey: .settled) ?? [:]
        }
    }

    private let fileURL: URL
    private var state: PersistedState

    init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(PersistedState.self, from: data) {
            var loaded = decoded
            // Evict on load as well as on write, so a ledger that aged while the
            // app was closed is trimmed before it is ever consulted.
            loaded.settled = Self.retainedSettledResponses(loaded.settled)
            self.state = loaded
        } else {
            // A missing or unreadable journal degrades to "remember nothing".
            // Losing anti-replay protection is bad; refusing to launch, or
            // never answering another command, is worse.
            self.state = PersistedState()
        }
    }

    var completedResponses: [SyncCommand] {
        state.completed.values.sorted { $0.id < $1.id }
    }

    var executingCommands: [SyncCommand] {
        state.executing.values.sorted { $0.id < $1.id }
    }

    var settledResponses: [SyncCommand] {
        state.settled.values.sorted { $0.id < $1.id }
    }

    func decision(for command: SyncCommand) -> SyncCommandDuplicateDecision {
        if let response = state.completed[command.id] {
            return .resendCompleted(response)
        }
        // Checked ahead of `executing` deliberately: the two can only overlap
        // through a bug, and if they ever do, re-publishing a known answer is
        // the harmless choice while re-entering execution is the harmful one.
        if let response = state.settled[command.id] {
            return .resendCompleted(response)
        }
        if let executing = state.executing[command.id] {
            return .reconcileExecuting(executing)
        }
        return .execute
    }

    func markExecuting(_ command: SyncCommand) throws {
        var nextState = state
        nextState.executing[command.id] = command
        try persist(nextState)
        state = nextState
    }

    func storeCompletedResponse(_ response: SyncCommand) throws {
        var nextState = state
        nextState.executing.removeValue(forKey: response.id)
        // A newer answer supersedes any settled one for the same command —
        // `.needsApproval` becoming `.done` once the user approves — so the
        // stale answer must not outlive it and get resent in its place.
        nextState.settled.removeValue(forKey: response.id)
        nextState.completed[response.id] = response
        try persist(nextState)
        state = nextState
    }

    /// Moves a confirmed response out of the outbox and into the anti-replay
    /// ledger. The outbox entry has done its job once CloudKit confirms the
    /// save; the memory that the command *was answered* has to survive, or a
    /// re-uploaded `.pending` duplicate reads as new work.
    func acknowledgeCompletedResponse(commandID: String) throws {
        var nextState = state
        if let acknowledged = nextState.completed.removeValue(forKey: commandID) {
            nextState.settled[commandID] = acknowledged
        }
        nextState.settled = Self.retainedSettledResponses(nextState.settled)
        try persist(nextState)
        state = nextState
    }

    /// Which already-answered commands still earn their disk space.
    ///
    /// Keyed on each command's own `expiresAt` rather than a separate retention
    /// window. `handleIncomingCommand` answers any expired command with
    /// `.expired` *before* it consults this journal, so past `expiresAt` a
    /// settled entry can never be reached and protects nothing. That makes the
    /// command's own TTL (`SyncCommand.defaultTTL`, 7 days) the exact bound,
    /// with no second constant to drift out of sync with it.
    static func retainedSettledResponses(
        _ settled: [String: SyncCommand],
        now: Date = Date(),
        countCap: Int = settledResponseCountCap
    ) -> [String: SyncCommand] {
        let unexpired = settled.filter { $0.value.expiresAt > now }
        guard unexpired.count > countCap else { return unexpired }

        // Over the backstop cap, drop the entries closest to expiring: their
        // protection was about to lapse anyway, so they cost the least.
        let retained = unexpired.values
            .sorted { ($0.expiresAt, $0.id) > ($1.expiresAt, $1.id) }
            .prefix(countCap)
        return Dictionary(uniqueKeysWithValues: retained.map { ($0.id, $0) })
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
