import Foundation
import CloudKit

/// This Mac's own copy of the state zone, kept current from its own change
/// feed (own token — never CKSyncEngine's, never the publish ledger). Shared
/// by the state-zone tab reconciliation and the live sync probe.
///
/// Why a mirror: a change feed read from a nil token pages through every past
/// change in the zone, not just the records that exist now. On a zone with
/// long tab churn that walk measured ~215 pages / 3.5–5 min, which the
/// reconcile used to repeat every 10 minutes. The mirror pays it once per
/// launch (and once per `fullWalkInterval`); every other catch-up is the
/// handful of pages changed since the last one.
///
/// Memory-only on purpose: a relaunch rebuilds it from a full walk, so a bad
/// mirror can never outlive the process — the same guarantee the reconcile's
/// old per-run full re-read gave, at a fraction of the cost.
///
/// Generic over the token so tests can drive the real walk with a fake feed
/// (`CKServerChangeToken` has no public initializer).
@MainActor
final class StateZoneMirror<Token> {
    /// One change-feed page, reduced to what the mirror applies.
    struct Page {
        var modifiedRecords: [CKRecord]
        /// Entries the server reported but could not deliver (per-record
        /// failures). Their stale copies leave the mirror, and the probe
        /// refuses to answer while any remain.
        var unreadableRecordNames: [String]
        var deletedRecordNames: [String]
        var token: Token
        var moreComing: Bool
    }

    struct CatchUpSummary: Equatable {
        var pageCount: Int
        var wasFullWalk: Bool
    }

    /// A reset (account change) landed mid-walk; the walk's pages belonged to
    /// the previous account and were discarded.
    struct ResetDuringCatchUp: Error {}

    /// Re-walk from scratch at least this often, so an incremental mirror is
    /// never trusted for longer than a day, and unreadable entries get
    /// another chance.
    nonisolated static var fullWalkInterval: TimeInterval { 24 * 60 * 60 }

    private(set) var recordsByName: [String: CKRecord] = [:]
    private(set) var unreadableRecordNames: Set<String> = []
    /// True from a start-over (first walk, expired token, rebaseline, reset)
    /// until a walk reaches the present: `records` is then partial and must
    /// not be answered from, even by a reader that skips `catchUp()`.
    private(set) var isRebuilding = true
    private var token: Token?
    private var lastFullWalkStartedAt: Date?
    private var generation = 0
    private var inFlightCatchUp: Task<CatchUpSummary, Error>?

    private let fetchPage: @MainActor (Token?) async throws -> Page
    private let isTokenExpired: (Error) -> Bool
    private let now: () -> Date

    init(
        fetchPage: @escaping @MainActor (Token?) async throws -> Page,
        isTokenExpired: @escaping (Error) -> Bool,
        now: @escaping () -> Date = Date.init
    ) {
        self.fetchPage = fetchPage
        self.isTokenExpired = isTokenExpired
        self.now = now
    }

    var records: [CKRecord] { Array(recordsByName.values) }

    /// Brings the mirror up to the server's present. Callers read `records`
    /// only after this returns without throwing, with no `await` in between
    /// (another walk could start over meanwhile): a walk that failed midway
    /// leaves a partial mirror, and the next catch-up resumes from its token.
    ///
    /// Serialized: two interleaved walks would each write the shared token
    /// and could replay an older page over a newer one. A call arriving
    /// mid-walk waits for it, then walks itself, so what it reads is never
    /// older than the moment it was called.
    @discardableResult
    func catchUp() async throws -> CatchUpSummary {
        while let running = inFlightCatchUp {
            _ = try? await running.value
        }
        // Cleared inside the task, before any waiter resumes, so a waiter
        // never re-awaits a finished walk.
        let walk = Task { @MainActor in
            defer { self.inFlightCatchUp = nil }
            return try await self.walkToPresent()
        }
        inFlightCatchUp = walk
        return try await walk.value
    }

    /// Forget everything (account change): the next catch-up is a full walk
    /// of whichever account is signed in by then.
    func reset() {
        generation += 1
        startOver()
    }

    private func startOver() {
        recordsByName.removeAll()
        unreadableRecordNames.removeAll()
        token = nil
        lastFullWalkStartedAt = nil
        isRebuilding = true
    }

    private func walkToPresent() async throws -> CatchUpSummary {
        let walkGeneration = generation
        if let lastFullWalkStartedAt, now().timeIntervalSince(lastFullWalkStartedAt) >= Self.fullWalkInterval {
            startOver()
        }
        var wasFullWalk = token == nil
        if wasFullWalk { lastFullWalkStartedAt = now() }
        var pageCount = 0
        while true {
            let page: Page
            do {
                page = try await fetchPage(token)
            } catch {
                // After a reset, whatever the old account's request threw is
                // not this account's failure.
                guard generation == walkGeneration else { throw ResetDuringCatchUp() }
                guard isTokenExpired(error), token != nil else { throw error }
                startOver()
                wasFullWalk = true
                lastFullWalkStartedAt = now()
                continue
            }
            guard generation == walkGeneration else { throw ResetDuringCatchUp() }
            apply(page)
            pageCount += 1
            guard page.moreComing else { break }
        }
        isRebuilding = false
        return CatchUpSummary(pageCount: pageCount, wasFullWalk: wasFullWalk)
    }

    private func apply(_ page: Page) {
        for record in page.modifiedRecords {
            let recordName = record.recordID.recordName
            recordsByName[recordName] = record
            unreadableRecordNames.remove(recordName)
        }
        for recordName in page.unreadableRecordNames {
            recordsByName.removeValue(forKey: recordName)
            unreadableRecordNames.insert(recordName)
        }
        for recordName in page.deletedRecordNames {
            recordsByName.removeValue(forKey: recordName)
            unreadableRecordNames.remove(recordName)
        }
        token = page.token
    }
}
