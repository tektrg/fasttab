import CloudKit
import Foundation

/// Where an app keeps its FastTab List, as sync sees it (the phone: `SavedOnIPhoneStore`).
@MainActor
public protocol FastTabListSyncStore: AnyObject {
    /// Every item, live and in Trash.
    func listItemsForSync() -> [SavedOnIPhoneLink]
    /// Another device's copy: merge it in (`FastTabListMerge`) and return what is now held.
    func applyRemoteListItem(_ item: SavedOnIPhoneLink) -> SavedOnIPhoneLink
    /// The record was deleted in CloudKit (purged / Trash emptied elsewhere).
    func removeRemoteListItem(id: String)
}

/// Keeps one device's FastTab List in step with `ReaderZone`, for any `CKSyncEngine` owner.
/// Same ledger model as `ReaderSyncBridge` (no outbox, so nothing is lost on a kill):
/// the ledger holds, per record, a hash of what CloudKit last confirmed or delivered.
/// - local item differs from the ledger → save (offline edits go out on the next launch);
/// - ledger entry with no local item → delete (an item purged here is deleted everywhere);
/// - a fetched record is merged per field, so re-sends are harmless (at-least-once safe);
/// - a CloudKit deletion removes the local item.
/// The ledger is written once per batch, so a first upload of thousands stays cheap.
@MainActor
public final class FastTabListSyncBridge {
    public let zoneID: CKRecordZone.ID
    private let store: FastTabListSyncStore
    private let ledgerURL: URL
    private var confirmed: [String: String]

    public init(ledgerURL: URL, store: FastTabListSyncStore, zoneID: CKRecordZone.ID = SyncConstants.readerZoneID) {
        self.ledgerURL = ledgerURL
        self.store = store
        self.zoneID = zoneID
        confirmed = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: ledgerURL))) ?? [:]
    }

    public static func handles(_ recordType: String) -> Bool {
        recordType == SyncedListItem.recordType
    }

    // MARK: - Sending

    /// Everything that differs from what CloudKit last confirmed.
    public func pendingChanges() -> (saves: [CKRecord], deletes: [CKRecord.ID]) {
        let local = store.listItemsForSync().map(SyncedListItem.init)
        let saves = local
            .filter { confirmed[$0.recordName] != ReaderSyncBridge.hash($0.payload) }
            .map { $0.toRecord(zoneID: zoneID) }
        let localNames = Set(local.map(\.recordName))
        let deletes = confirmed.keys
            .filter { !localNames.contains($0) }
            .sorted()
            .map { CKRecord.ID(recordName: $0, zoneID: zoneID) }
        return (saves, deletes)
    }

    /// CloudKit confirmed these saves (non-list records are ignored).
    public func didSave(_ records: [CKRecord]) {
        var changed = false
        for record in records {
            guard let synced = SyncedListItem(from: record) else { continue }
            confirmed[synced.recordName] = ReaderSyncBridge.hash(synced.payload)
            changed = true
        }
        if changed { saveLedger() }
    }

    /// CloudKit confirmed these deletes (or the record was already gone).
    public func didDelete(_ recordIDs: [CKRecord.ID]) {
        var changed = false
        for recordID in recordIDs where recordID.zoneID == zoneID {
            changed = confirmed.removeValue(forKey: recordID.recordName) != nil || changed
        }
        if changed { saveLedger() }
    }

    public func outcome(ofFailedSave record: CKRecord, error: Error) -> ReaderSyncBridge.FailedSaveOutcome {
        guard Self.handles(record.recordType) else { return .notReader }
        guard let ckError = error as? CKError else { return .failed }
        switch ckError.code {
        case .serverRecordChanged:
            // Another device (or an earlier send of ours) got there first: merge, then send
            // the merge on the server's change tag, unless it already says everything.
            guard let serverRecord = ckError.serverRecord, let server = SyncedListItem(from: serverRecord) else { return .failed }
            let merged = SyncedListItem(store.applyRemoteListItem(server.item))
            confirmed[server.recordName] = ReaderSyncBridge.hash(server.payload)
            saveLedger()
            return merged.payload == server.payload ? .settled : .retry(merged.applying(to: serverRecord))
        case .unknownItem:
            // Deleted in CloudKit while we were editing: the delete wins.
            absorbDeletions([record.recordID])
            return .settled
        default:
            return .failed
        }
    }

    // MARK: - Receiving

    /// Merges fetched list records into the store. A record this device has purged but not
    /// yet deleted in CloudKit is skipped: the delete goes out next and wins.
    public func absorb(_ records: [CKRecord]) {
        let localIDs = Set(store.listItemsForSync().map(\.id))
        var changed = false
        for record in records {
            guard let remote = SyncedListItem(from: record) else { continue }
            let name = remote.recordName
            let purgedHere = confirmed[name] != nil && !localIDs.contains(remote.item.id)
            guard !purgedHere else { continue }
            store.applyRemoteListItem(remote.item)
            confirmed[name] = ReaderSyncBridge.hash(remote.payload)
            changed = true
        }
        if changed { saveLedger() }
    }

    public func absorbDeletions(_ recordIDs: [CKRecord.ID]) {
        var changed = false
        for recordID in recordIDs where recordID.zoneID == zoneID {
            let name = recordID.recordName
            guard name.hasPrefix(SyncedListItem.namePrefix) else { continue }
            store.removeRemoteListItem(id: String(name.dropFirst(SyncedListItem.namePrefix.count)))
            changed = confirmed.removeValue(forKey: name) != nil || changed
        }
        if changed { saveLedger() }
    }

    /// A different iCloud account: nothing there is confirmed. Local items stay and are
    /// all uploaded again.
    public func resetLedger() {
        confirmed = [:]
        saveLedger()
    }

    // MARK: - Private

    private func saveLedger() {
        do {
            try FileManager.default.createDirectory(
                at: ledgerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(confirmed).write(to: ledgerURL, options: .atomic)
        } catch {
            // Losing the ledger only re-sends items; the merge makes re-sends no-ops.
        }
    }
}
