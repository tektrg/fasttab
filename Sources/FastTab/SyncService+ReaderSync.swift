import CloudKit
import FastTabReader
import FastTabSync
import Foundation

extension Notification.Name {
    /// The reader mirror took changes from the phone (Settings > Highlights reloads).
    static let readerMirrorDidChange = Notification.Name("FastTab.readerMirrorDidChange")
}

// Reader highlights and comment threads from the phone (`ReaderZone`), mirrored to disk by
// `ReaderMirror` through the shared `ReaderSyncBridge`. Comments written on this Mac (agent
// tools) go back the same way.

extension SyncService {
    /// The mirror as Settings > Highlights reads and writes it; same comment store as sync.
    var readerLibrary: ReaderLibrary {
        ReaderLibrary(directory: ReaderMirror.directory(supportDirectory: fastTabSupportDirectory),
                      comments: readerSync.comments)
    }

    /// Arms whatever the bridge says CloudKit lacks. Called at start and on every poll tick;
    /// confirmed records are skipped, armed ones are not re-armed.
    func queueReaderChanges() {
        guard let syncEngine else { return }
        Task { @MainActor in
            let pending = await readerSync.pendingChanges()
            guard !pending.saves.isEmpty || !pending.deletes.isEmpty else { return }
            let armed = Set(syncEngine.state.pendingRecordZoneChanges.compactMap { change -> CKRecord.ID? in
                switch change {
                case .saveRecord(let id), .deleteRecord(let id): return id
                @unknown default: return nil
                }
            })
            // An armed save may be a conflict retry carrying the server's change tag: keep it.
            for record in pending.saves where !armed.contains(record.recordID) {
                pendingRecordsToSave[record.recordID] = record
            }
            syncEngine.state.add(pendingRecordZoneChanges:
                pending.saves.map(\.recordID).filter { !armed.contains($0) }.map { .saveRecord($0) }
                + pending.deletes.filter { !armed.contains($0) }.map { .deleteRecord($0) })
            sendPendingChanges()
        }
    }

    func absorbReaderChanges(_ records: [CKRecord], deletions: [CKRecord.ID]) {
        let readerRecords = records.filter { ReaderSyncBridge.handles($0.recordType) }
        let readerDeletions = deletions.filter { $0.zoneID == SyncConstants.readerZoneID }
        guard !readerRecords.isEmpty || !readerDeletions.isEmpty else { return }
        Task { @MainActor in
            await readerSync.absorb(readerRecords)
            readerSync.absorbDeletions(readerDeletions)
            NotificationCenter.default.post(name: .readerMirrorDidChange, object: nil)
        }
    }
}
