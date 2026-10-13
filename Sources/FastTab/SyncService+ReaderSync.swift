import CloudKit
import FastTabSync
import Foundation

// Reader highlights and comment threads from the phone (`ReaderZone`), mirrored to disk by
// `ReaderMirror` through the shared `ReaderSyncBridge`. Comments written on this Mac (agent
// tools) go back the same way.

extension SyncService {
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
            for record in pending.saves {
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
        }
    }
}
