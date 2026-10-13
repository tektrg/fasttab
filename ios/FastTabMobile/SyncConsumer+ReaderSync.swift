import CloudKit
import Foundation
import FastTabSync

// Reader highlights and their comment threads in `ReaderZone`, through the shared
// `ReaderSyncBridge`. The engine plumbing in SyncConsumer+SyncEngineDelegate.swift hands
// reader records here and otherwise stays as it was.

extension SyncConsumer {
    static let readerLedgerFileName = "ios_reader_sync_ledger.json"

    /// Arms a save or delete for everything the bridge says CloudKit lacks, then sends.
    /// Safe to call often: confirmed records are skipped and armed ones are not re-armed.
    func queueReaderChanges(send: Bool = true) async {
        guard let syncEngine else { return }
        let pending = await readerSync.pendingChanges()
        guard !pending.saves.isEmpty || !pending.deletes.isEmpty else { return }
        let armed = Self.armedSaveIDs(in: syncEngine.state.pendingRecordZoneChanges)
        let armedDeletes = Set(syncEngine.state.pendingRecordZoneChanges.compactMap { change -> CKRecord.ID? in
            if case .deleteRecord(let id) = change { return id } else { return nil }
        })
        for record in pending.saves {
            pendingRecordsToSave[record.recordID] = record
        }
        syncEngine.state.add(pendingRecordZoneChanges:
            pending.saves.filter { !armed.contains($0.recordID) }.map { .saveRecord($0.recordID) }
            + pending.deletes.filter { !armedDeletes.contains($0) }.map { .deleteRecord($0) })
        if send { sendPendingChanges() }
    }

    /// Applies fetched reader records and deletions, then refreshes the open threads.
    func absorbReaderChanges(
        _ records: [CKRecord], deletions: [CKRecord.ID]
    ) async {
        let readerRecords = records.filter { ReaderSyncBridge.handles($0.recordType) }
        let readerDeletions = deletions.filter { $0.zoneID == SyncConstants.readerZoneID }
        guard !readerRecords.isEmpty || !readerDeletions.isEmpty else { return }
        await readerSync.absorb(readerRecords)
        readerSync.absorbDeletions(readerDeletions)
        ReaderCommentThreads.shared.reloadAfterSync()
    }

    /// Debounced: a burst of local edits (a comment, then its highlight link) sends once.
    func observeLocalReaderChanges() {
        readerChangeObserver = NotificationCenter.default.addObserver(
            forName: .readerDataDidChangeLocally, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.readerSendTask?.cancel()
                self.readerSendTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else { return }
                    await self.queueReaderChanges()
                }
            }
        }
    }
}
