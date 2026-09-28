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
                    // backlog cannot be sent until they exist again.
                    self.ensureZonesExist()
                    self.restorePendingCommandOutbox()
                    self.ownDeviceServerRecord = nil
                    self.publishOwnDevice()
                    self.sendPendingChanges()
                case .signOut:
                    break
                @unknown default:
                    break
                }
                self.fetchLatestChanges()

            case .fetchedRecordZoneChanges(let fetchedChanges):
                for modification in fetchedChanges.modifications {
                    let record = modification.record
                    switch record.recordType {
                    case SyncedDevice.recordType:
                        // Our own heartbeat comes back too; keep its change tag,
                        // and let the cache drop it (it holds Macs only).
                        self.retainOwnDeviceRecordIfMine(record)
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

                for deletion in fetchedChanges.deletions {
                    let recordName = deletion.recordID.recordName
                    let zoneID = deletion.recordID.zoneID
                    if zoneID == SyncConstants.stateZoneID {
                        LocalCache.shared.removeTab(id: recordName)
                        LocalCache.shared.removeTabOrder(id: recordName)
                        LocalCache.shared.removeDevice(id: recordName)
                        LocalCache.shared.removeBookmarkBlob(id: recordName)
                        LocalCache.shared.removeHistorySlice(id: recordName)
                        LocalCache.shared.removeTabStats(recordName: recordName)
                    }
                }

                LocalCache.shared.flushPendingSave()

            case .sentRecordZoneChanges(let sentChanges):
                for saved in sentChanges.savedRecords {
                    self.confirmUpload(of: saved)
                }
                if !sentChanges.savedRecords.isEmpty {
                    self.markSyncSucceeded()
                }

                var queuedRetry = false
                var needsZoneRecreation = false
                for failedSave in sentChanges.failedRecordSaves {
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
                    } else {
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
