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
// tools) go back the same way. The FastTab List (read-later items) shares the zone through
// `FastTabListSyncBridge`; this Mac both receives and edits it (`FastTabListStore`).

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
            let readerPending = await readerSync.pendingChanges()
            let listPending = listSync.pendingChanges()
            let pending = (saves: readerPending.saves + listPending.saves,
                           deletes: readerPending.deletes + listPending.deletes)
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
        listSync.absorb(records.filter { FastTabListSyncBridge.handles($0.recordType) })
        listSync.absorbDeletions(readerDeletions)
        guard !readerRecords.isEmpty || !readerDeletions.isEmpty else { return }
        Task { @MainActor in
            await readerSync.absorb(readerRecords)
            readerSync.absorbDeletions(readerDeletions)
            NotificationCenter.default.post(name: .readerMirrorDidChange, object: nil)
        }
    }

    /// Reads `ReaderZone` changes straight from CloudKit since the last saved token. Why: the
    /// engine fetches only after a push marks a zone dirty ("no zone IDs needing to be
    /// fetched"), and pushes don't reliably reach this Mac, so phone comments arrived only on
    /// relaunch (seen 2026-10-13). Same remedy as the commands-zone sweep.
    func catchUpReaderZone() {
        guard !readerZoneCatchUpInFlight else { return }
        readerZoneCatchUpInFlight = true
        Task { @MainActor in
            defer { readerZoneCatchUpInFlight = false }
            let tokenURL = ReaderMirror.directory(supportDirectory: fastTabSupportDirectory)
                .appendingPathComponent("zone_change_token.dat")
            var token = (try? Data(contentsOf: tokenURL)).flatMap {
                try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0)
            }
            do {
                while true {
                    let changes = try await database.recordZoneChanges(inZoneWith: SyncConstants.readerZoneID, since: token)
                    let records = changes.modificationResultsByID.values.compactMap { try? $0.get().record }
                    await readerSync.absorb(records)
                    readerSync.absorbDeletions(changes.deletions.map(\.recordID))
                    listSync.absorb(records.filter { FastTabListSyncBridge.handles($0.recordType) })
                    listSync.absorbDeletions(changes.deletions.map(\.recordID))
                    token = changes.changeToken
                    if let data = try? NSKeyedArchiver.archivedData(withRootObject: changes.changeToken, requiringSecureCoding: true) {
                        try? data.write(to: tokenURL, options: .atomic)
                    }
                    if !records.isEmpty || !changes.deletions.isEmpty {
                        NotificationCenter.default.post(name: .readerMirrorDidChange, object: nil)
                    }
                    guard changes.moreComing else { break }
                }
            } catch let error as CKError where error.code == .changeTokenExpired {
                try? FileManager.default.removeItem(at: tokenURL)
            } catch let error as CKError where error.code == .zoneNotFound {
                // No reader data yet; the phone creates the zone with its first highlight.
            } catch {
                logger.error("Reader zone catch-up failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - FastTab List

    /// List changes come in bursts (several trashes in a row): send at most this often.
    static let fastTabListSendDebounce: Duration = .seconds(2)

    func observeLocalFastTabListChanges() {
        guard listChangeObserver == nil else { return }
        listChangeObserver = NotificationCenter.default.addObserver(
            forName: .fastTabListDidChangeLocally, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.listSendTask?.cancel()
                self.listSendTask = Task { @MainActor in
                    try? await Task.sleep(for: Self.fastTabListSendDebounce)
                    guard !Task.isCancelled else { return }
                    self.queueReaderChanges()
                }
            }
        }
    }

    /// A fresh or swapped iCloud account has none of this Mac's list confirmed: upload it all.
    func resendFastTabListToNewAccount() {
        listSync.resetLedger()
        queueReaderChanges()
    }

    /// Reader highlights first, then list items (each bridge ignores the other's records).
    func readerZoneOutcome(ofFailedSave record: CKRecord, error: Error) -> ReaderSyncBridge.FailedSaveOutcome {
        let readerOutcome = readerSync.outcome(ofFailedSave: record, error: error)
        if case .notReader = readerOutcome {
            return listSync.outcome(ofFailedSave: record, error: error)
        }
        return readerOutcome
    }

    /// A reader-zone delete of a record that is already gone is done, not a retry.
    func settleAlreadyDeletedReaderRecord(_ recordID: CKRecord.ID, error: Error) -> Bool {
        guard recordID.zoneID == SyncConstants.readerZoneID,
              (error as? CKError)?.code == .unknownItem else { return false }
        readerSync.didDelete(recordID)
        listSync.didDelete([recordID])
        return true
    }
}
