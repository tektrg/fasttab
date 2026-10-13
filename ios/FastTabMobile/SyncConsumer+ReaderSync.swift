import CloudKit
import Foundation
import FastTabSync

// Reader highlights and their comment threads in `ReaderZone`, through the shared
// `ReaderSyncBridge`. The engine plumbing in SyncConsumer+SyncEngineDelegate.swift hands
// reader records here and otherwise stays as it was.

extension SyncConsumer {
    static let readerLedgerFileName = "ios_reader_sync_ledger.json"

    /// Debug builds: one line per reader-sync step in Documents/reader-sync.log, readable
    /// over the cable (`devicectl device copy from`). Release builds write nothing.
    nonisolated static func readerTrace(_ message: @autoclosure () -> String) {
        #if DEBUG
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = dir.appendingPathComponent("reader-sync.log")
        let line = Data("\(ISO8601DateFormatter().string(from: Date())) \(message())\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
            try? handle.close()
        } else {
            try? line.write(to: url)
        }
        #endif
    }

    /// Arms a save or delete for everything the bridge says CloudKit lacks, then sends.
    /// Safe to call often: confirmed records are skipped and armed ones are not re-armed.
    func queueReaderChanges(send: Bool = true) async {
        guard let syncEngine else { Self.readerTrace("queue: no engine"); return }
        let pending = await readerSync.pendingChanges()
        Self.readerTrace("queue: saves=\(pending.saves.map(\.recordID.recordName)) deletes=\(pending.deletes.map(\.recordName)) armedTotal=\(syncEngine.state.pendingRecordZoneChanges.count)")
        guard !pending.saves.isEmpty || !pending.deletes.isEmpty else { return }
        let armed = Self.armedSaveIDs(in: syncEngine.state.pendingRecordZoneChanges)
        let armedDeletes = Set(syncEngine.state.pendingRecordZoneChanges.compactMap { change -> CKRecord.ID? in
            if case .deleteRecord(let id) = change { return id } else { return nil }
        })
        // An armed save may be a conflict retry carrying the server's change tag: keep it.
        for record in pending.saves where !armed.contains(record.recordID) {
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
        Self.readerTrace("fetched: \(readerRecords.map(\.recordID.recordName)) deleted: \(readerDeletions.map(\.recordName))")
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
