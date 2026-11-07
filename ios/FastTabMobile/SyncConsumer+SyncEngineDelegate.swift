import Foundation
import CloudKit
import OSLog
import FastTabSync

// Split out of SyncConsumer.swift: the CloudKit event plumbing is long enough to
// obscure the command/health logic it drives.

// MARK: - CKSyncEngineDelegate

extension SyncConsumer: CKSyncEngineDelegate {
    nonisolated public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) {
        Task { @MainActor in
            switch event {
            case .stateUpdate(let update):
                self.saveStateSerialization(update.stateSerialization)

            case .accountChange(let accountChange):
                await self.refreshAccountStatus()
                switch accountChange.changeType {
                case .signIn, .switchAccounts:
                    // A fresh or swapped account has no zones of ours yet; the
                    // backlog cannot be sent until they exist again. Nothing in it is
                    // confirmed either: the FastTab List stays local and uploads again.
                    self.listSync.resetLedger()
                    self.resetZoneSweepTokens()
                    self.ensureZonesExist()
                    self.restorePendingCommandOutbox()
                    self.ownDeviceServerRecord = nil
                    self.publishOwnDevice()
                    await self.queueReaderChanges(send: false)
                    self.sendPendingChanges()
                case .signOut:
                    break
                @unknown default:
                    break
                }
                self.fetchLatestChanges()

            case .fetchedRecordZoneChanges(let fetchedChanges):
                await self.applyFetchedChanges(
                    modifications: fetchedChanges.modifications.map(\.record),
                    deletions: fetchedChanges.deletions.map(\.recordID))

            case .sentRecordZoneChanges(let sentChanges):
                Self.readerTrace("sent: saved=\(sentChanges.savedRecords.map(\.recordID.recordName)) failed=\(sentChanges.failedRecordSaves.map { "\($0.record.recordID.recordName): \($0.error.code.rawValue)" })")
                for saved in sentChanges.savedRecords {
                    self.confirmUpload(of: saved)
                    if ReaderSyncBridge.handles(saved.recordType) { self.readerSync.didSave(saved) }
                }
                self.listSync.didSave(sentChanges.savedRecords)
                for deletedID in sentChanges.deletedRecordIDs {
                    self.readerSync.didDelete(deletedID)
                }
                self.listSync.didDelete(sentChanges.deletedRecordIDs)
                for (recordID, error) in sentChanges.failedRecordDeletes where recordID.zoneID == SyncConstants.readerZoneID {
                    // Only reader highlights and purged list items are deleted from here. Already
                    // gone counts as done; a passing failure retries (the engine backs off);
                    // anything else gives up.
                    if (error as CKError).code == .unknownItem {
                        self.readerSync.didDelete(recordID)
                        self.listSync.didDelete([recordID])
                    } else if SyncHealthMapping.isWorthRetrying(error) {
                        syncEngine.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
                    } else {
                        self.markSyncFailed(error, whileDoing: "deleting a reader record")
                    }
                }
                if !sentChanges.savedRecords.isEmpty {
                    self.markSyncSucceeded()
                }

                var queuedRetry = false
                var needsZoneRecreation = false
                for failedSave in sentChanges.failedRecordSaves {
                    let readerOutcome = self.readerSync.outcome(ofFailedSave: failedSave.record, error: failedSave.error)
                    let outcome: ReaderSyncBridge.FailedSaveOutcome
                    if case .notReader = readerOutcome {
                        outcome = self.listSync.outcome(ofFailedSave: failedSave.record, error: failedSave.error)
                    } else {
                        outcome = readerOutcome
                    }
                    switch outcome {
                    case .notReader, .failed:
                        break
                    case .settled:
                        self.pendingRecordsToSave.removeValue(forKey: failedSave.record.recordID)
                        continue
                    case .retry(let retryRecord):
                        // Queued only: the engine sends it on its own. Calling sendChanges()
                        // here, while this send is still finishing, trips a CloudKit assertion
                        // (crashed on device 2026-10-13 when a comment's highlight hit a conflict).
                        self.pendingRecordsToSave[retryRecord.recordID] = retryRecord
                        syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(retryRecord.recordID)])
                        continue
                    }
                    if let retryRecord = Self.recordForRetry(
                        intendedRecord: failedSave.record,
                        error: failedSave.error
                    ) {
                        self.retainOwnDeviceRecordIfMine(retryRecord)
                        self.pendingRecordsToSave[retryRecord.recordID] = retryRecord
                        syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(retryRecord.recordID)])
                        queuedRetry = true
                        self.logger.info("Reconciled record conflict and queued retry for \(retryRecord.recordID.recordName, privacy: .public)")
                    } else if SyncHealthMapping.isWorthRetrying(failedSave.error) {
                        // Always stays in the outbox. Whether to re-arm depends
                        // on who owns the retry: the engine backs off and
                        // retries the network-ish failures itself, and an
                        // immediate re-send there would spin on a dead network.
                        if SyncHealthMapping.isMissingZone(failedSave.error) {
                            needsZoneRecreation = true
                        } else if !SyncHealthMapping.isRetriedByEngine(failedSave.error) {
                            syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(failedSave.record.recordID)])
                        }
                        self.markSyncFailed(failedSave.error, whileDoing: "saving a change")
                    } else if !self.abandonRejectedHeartbeat(failedSave.record, error: failedSave.error) {
                        self.abandonUnsendableCommand(failedSave.record, error: failedSave.error)
                        self.markSyncFailed(failedSave.error, whileDoing: "saving a change")
                    }
                }
                if needsZoneRecreation {
                    // The zone was deleted out from under us; recreate it,
                    // re-arm the backlog, and let the engine send again.
                    self.ensureZonesExist()
                    self.restorePendingCommandOutbox()
                    queuedRetry = true
                }
                if queuedRetry {
                    self.sendPendingChanges()
                }

            case .sentDatabaseChanges(let databaseChanges):
                for failedSave in databaseChanges.failedZoneSaves {
                    self.markSyncFailed(failedSave.error, whileDoing: "creating an iCloud zone")
                }

            case .fetchedDatabaseChanges,
                 .willFetchChanges,
                 .didFetchChanges,
                 .willFetchRecordZoneChanges,
                 .didFetchRecordZoneChanges,
                 .willSendChanges,
                 .didSendChanges:
                break

            @unknown default:
                break
            }
        }
    }

    nonisolated public func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let (pendingChanges, records) = await MainActor.run {
            (syncEngine.state.pendingRecordZoneChanges, self.pendingRecordsToSave)
        }
        guard !pendingChanges.isEmpty else { return nil }
        Self.readerTrace("batch: pending=\(pendingChanges.count) bodies=\(records.count) zones=\(Set(pendingChanges.map { change -> String in switch change { case .saveRecord(let id), .deleteRecord(let id): return id.zoneID.zoneName; @unknown default: return "?" } }))")

        // Never hand the engine a silent nil: a pending save with no record body
        // is a bug (the outbox should have restored it), and leaving it in place
        // means the engine drops it without ever reporting a failure.
        let unsatisfiable = Self.unsatisfiablePendingSaveIDs(
            pendingChanges: pendingChanges,
            availableRecords: records
        )
        if !unsatisfiable.isEmpty {
            // Back on the MainActor: another queue/restore may have supplied a
            // body since the snapshot, and that change must not be discarded —
            // nor reported as a fault.
            await MainActor.run {
                let stillUnsatisfiable = unsatisfiable.filter { self.pendingRecordsToSave[$0] == nil }
                guard !stillUnsatisfiable.isEmpty else { return }
                for recordID in stillUnsatisfiable {
                    self.logger.error("No record body for pending save \(recordID.recordName, privacy: .public); discarding the stale pending change")
                }
                syncEngine.state.remove(pendingRecordZoneChanges: stillUnsatisfiable.map { .saveRecord($0) })
            }
        }

        let deliverable = Self.deliverablePendingChanges(
            pendingChanges: pendingChanges,
            excludingSaveIDs: Set(unsatisfiable)
        )
        guard !deliverable.isEmpty else { return nil }

        return await CKSyncEngine.RecordZoneChangeBatch(
            pendingChanges: deliverable,
            recordProvider: { recordID in
                records[recordID]
            }
        )
    }
}

// MARK: - Applying fetched records

extension SyncConsumer {
    /// Applies records read from CloudKit to the local cache. One path for the engine's
    /// fetch events and for the manual zone sweep (SyncConsumer+ZoneSweep.swift), so both
    /// produce the same result.
    func applyFetchedChanges(modifications: [CKRecord], deletions: [CKRecord.ID]) async {
        for record in modifications {
            switch record.recordType {
            case SyncedDevice.recordType:
                // Our own heartbeat comes back too; keep its change tag,
                // and let the cache drop it (it holds Macs only).
                retainOwnDeviceRecordIfMine(record)
                if let device = SyncedDevice(from: record) {
                    LocalCache.shared.updateDevice(device)
                }
            case SyncedTab.recordType:
                if let tab = SyncedTab(from: record) {
                    LocalCache.shared.updateTab(tab)
                }
            case SyncedTabOrder.recordType:
                if let tabOrder = SyncedTabOrder(from: record) {
                    LocalCache.shared.updateTabOrder(tabOrder)
                }
            case SyncedBookmarkBlob.recordType:
                if let blob = SyncedBookmarkBlob(from: record) {
                    LocalCache.shared.updateBookmarkBlob(blob)
                }
            case SyncedHistorySlice.recordType:
                if let slice = SyncedHistorySlice(from: record) {
                    LocalCache.shared.updateHistorySlice(slice)
                }
            case SyncedTabStats.recordType:
                if let stats = SyncedTabStats(from: record) {
                    LocalCache.shared.updateTabStats(stats)
                }
            case SyncedFavicons.recordType:
                if let favicons = SyncedFavicons(from: record) {
                    FaviconModel.shared.apply(favicons)
                }
            case SyncCommand.recordType:
                if let command = SyncCommand(from: record) {
                    LocalCache.shared.updateCommandStatus(
                        id: command.id,
                        status: command.status,
                        reason: command.statusReason,
                        completedAt: command.completedAt
                    )
                }
            default:
                break
            }
        }

        for deletionID in deletions {
            let recordName = deletionID.recordName
            let zoneID = deletionID.zoneID
            if zoneID == SyncConstants.stateZoneID {
                LocalCache.shared.removeTab(id: recordName)
                LocalCache.shared.removeTabOrder(id: recordName)
                LocalCache.shared.removeDevice(id: recordName)
                LocalCache.shared.removeBookmarkBlob(id: recordName)
                LocalCache.shared.removeHistorySlice(id: recordName)
                LocalCache.shared.removeTabStats(recordName: recordName)
                FaviconModel.shared.remove(recordName: recordName)
            }
        }

        LocalCache.shared.flushPendingSave()
        await absorbReaderChanges(
            modifications,
            deletions: deletions)
    }
}
