import CloudKit
import CryptoKit
import Foundation
import IndieComments

/// Where an app keeps its reader highlights, as the sync sees them. The phone backs it with
/// `ReaderHighlightStore`; the Mac with a mirror file.
@MainActor
public protocol ReaderHighlightSyncStore: AnyObject {
    /// Every local highlight, payloads encoded with sorted keys.
    func syncedHighlights() -> [SyncedReaderHighlight]
    /// Another device added or edited one: store it as given.
    func applyRemote(_ highlight: SyncedReaderHighlight)
    /// Another device deleted one (its comments arrive as their own delete events).
    func removeRemote(id: String)
}

/// Keeps one device's reader highlights and comment logs in step with `ReaderZone`, for any
/// `CKSyncEngine` owner (the phone's `SyncConsumer`, the Mac's `SyncService`).
///
/// No outbox: a ledger records what CloudKit last confirmed per record (a payload hash).
/// Anything local that differs from the ledger is sent, ledger entries with no local
/// highlight are deleted, so a change made offline or before a relaunch always goes out.
/// Comment events are append-only and never deleted.
@MainActor
public final class ReaderSyncBridge {
    public enum FailedSaveOutcome {
        /// Not a reader record; the caller handles it as before.
        case notReader
        /// Already there (an event someone else uploaded): nothing more to do.
        case settled
        /// Send this instead (the server copy carrying our fields: last write wins).
        case retry(CKRecord)
        /// Leave it to the caller's usual error handling.
        case failed
    }

    public let zoneID: CKRecordZone.ID
    public let comments: CommentStore
    private let highlights: ReaderHighlightSyncStore
    private let ledgerURL: URL
    /// Record name → hash of the payload CloudKit last confirmed (or delivered).
    private var confirmed: [String: String]

    public init(
        ledgerURL: URL,
        comments: CommentStore,
        highlights: ReaderHighlightSyncStore,
        zoneID: CKRecordZone.ID = SyncConstants.readerZoneID
    ) {
        self.ledgerURL = ledgerURL
        self.comments = comments
        self.highlights = highlights
        self.zoneID = zoneID
        confirmed = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: ledgerURL))) ?? [:]
    }

    public static func handles(_ recordType: String) -> Bool {
        recordType == SyncedReaderHighlight.recordType || recordType == SyncedCommentEvent.recordType
    }

    // MARK: - Sending

    /// Everything that differs from what CloudKit last confirmed.
    public func pendingChanges() async -> (saves: [CKRecord], deletes: [CKRecord.ID]) {
        var saves: [CKRecord] = []
        let localHighlights = highlights.syncedHighlights()
        for highlight in localHighlights where confirmed[highlight.recordName] != Self.hash(highlight.payload) {
            saves.append(highlight.toRecord(zoneID: zoneID))
        }
        for event in await localCommentEvents() where confirmed[event.recordName] == nil {
            saves.append(event.toRecord(zoneID: zoneID))
        }
        let localNames = Set(localHighlights.map(\.recordName))
        let deletes = confirmed.keys
            .filter { $0.hasPrefix(SyncedReaderHighlight.namePrefix) && !localNames.contains($0) }
            .sorted()
            .map { CKRecord.ID(recordName: $0, zoneID: zoneID) }
        return (saves, deletes)
    }

    public func didSave(_ record: CKRecord) {
        guard let hash = Self.payloadHash(of: record) else { return }
        confirmed[record.recordID.recordName] = hash
        saveLedger()
    }

    public func didDelete(_ recordID: CKRecord.ID) {
        guard recordID.zoneID == zoneID, confirmed.removeValue(forKey: recordID.recordName) != nil else { return }
        saveLedger()
    }

    public func outcome(ofFailedSave record: CKRecord, error: Error) -> FailedSaveOutcome {
        guard Self.handles(record.recordType) else { return .notReader }
        guard let ckError = error as? CKError else { return .failed }
        switch (ckError.code, record.recordType) {
        case (.serverRecordChanged, SyncedCommentEvent.recordType):
            didSave(record)
            return .settled
        case (.serverRecordChanged, SyncedReaderHighlight.recordType):
            guard let server = ckError.serverRecord, let mine = SyncedReaderHighlight(from: record) else { return .failed }
            return .retry(mine.applying(to: server))
        case (.unknownItem, SyncedReaderHighlight.recordType):
            return SyncedReaderHighlight(from: record).map { .retry($0.toRecord(zoneID: zoneID)) } ?? .failed
        default:
            return .failed
        }
    }

    // MARK: - Receiving

    /// Applies fetched reader records. A highlight edited here and not yet sent keeps the
    /// local version (it goes out next and wins); otherwise the remote copy replaces it.
    public func absorb(_ records: [CKRecord]) async {
        var eventsByDoc: [String: [CommentEvent]] = [:]
        let localPayloads = Dictionary(
            highlights.syncedHighlights().map { ($0.recordName, Self.hash($0.payload)) }, uniquingKeysWith: { $1 })
        for record in records {
            if let highlight = SyncedReaderHighlight(from: record) {
                let remoteHash = Self.hash(highlight.payload)
                let local = localPayloads[highlight.recordName]
                let editedLocally = local != nil && local != confirmed[highlight.recordName]
                if !editedLocally {
                    if local != remoteHash { highlights.applyRemote(highlight) }
                    confirmed[highlight.recordName] = remoteHash
                }
            } else if let synced = SyncedCommentEvent(from: record),
                      let event = try? JSONDecoder().decode(CommentEvent.self, from: synced.payload) {
                eventsByDoc[synced.docId, default: []].append(event)
                confirmed[synced.recordName] = Self.hash(synced.payload)
            }
        }
        for (docId, events) in eventsByDoc {
            _ = try? await comments.importEvents(events, docId: docId)
        }
        saveLedger()
    }

    public func absorbDeletions(_ recordIDs: [CKRecord.ID]) {
        var changed = false
        for recordID in recordIDs where recordID.zoneID == zoneID {
            let name = recordID.recordName
            guard name.hasPrefix(SyncedReaderHighlight.namePrefix) else { continue }
            highlights.removeRemote(id: String(name.dropFirst(SyncedReaderHighlight.namePrefix.count)))
            changed = confirmed.removeValue(forKey: name) != nil || changed
        }
        if changed { saveLedger() }
    }

    // MARK: - Private

    private func localCommentEvents() async -> [SyncedCommentEvent] {
        let all = (try? await comments.allEvents()) ?? []
        return all.compactMap { docId, event in
            (try? Self.encoder.encode(event)).map { SyncedCommentEvent(eventID: event.id, docId: docId, payload: $0) }
        }
    }

    private func saveLedger() {
        do {
            try FileManager.default.createDirectory(
                at: ledgerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(confirmed).write(to: ledgerURL, options: .atomic)
        } catch {
            // Losing the ledger only re-sends records; CloudKit treats them as no-op updates.
        }
    }

    private static func payloadHash(of record: CKRecord) -> String? {
        (record.encryptedValues["payload"] as? Data).map(hash)
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Sorted keys: the same event or highlight always encodes to the same bytes.
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
}
