import Foundation
import CloudKit
import FastTabSync

// Mac side of the history-free fast path (`MacStateDirectory`, FastTabSync): keep
// one small list of this Mac's live StateZone records in a fixed-ID record, so a
// phone can fetch the Mac's current state by ID instead of walking StateZone's
// change history.
//
// Written directly (not through CKSyncEngine): it is a single, re-derivable
// record with its own retry/backoff, and a failure here must never hold up or
// colour the real sync. In particular it does not touch sync health, so a
// Production container whose schema lacks this record type keeps syncing exactly
// as before; the write just keeps backing off.

/// What the directory writer remembers between writes (`SyncService.macDirectory`).
struct MacDirectoryPublishState {
    /// This Mac's StateZone records CloudKit confirmed. Persisted.
    var ledger = OwnedStateRecordLedger()
    /// The entry last written successfully this launch; nil = write on next chance.
    var publishedEntry: MacStateDirectoryEntry?
    /// Server copy of the shared directory record (change tag for the next save).
    var serverRecord: CKRecord?
    var writeTask: Task<Void, Never>?
    var lastWriteAt: Date?
    var retryAfter: Date?
    var failures = 0
}

extension SyncService {
    nonisolated static func ownedRecordLedgerURL(supportDirectory: URL) -> URL {
        supportDirectory.appendingPathComponent("mac_state_directory_ledger.json")
    }

    nonisolated static func loadOwnedRecordLedger(supportDirectory: URL) -> OwnedStateRecordLedger {
        guard let data = try? Data(contentsOf: ownedRecordLedgerURL(supportDirectory: supportDirectory)),
              let ledger = try? JSONDecoder().decode(OwnedStateRecordLedger.self, from: data) else {
            return OwnedStateRecordLedger()
        }
        return ledger
    }

    func persistOwnedRecordLedger() {
        do {
            let data = try JSONEncoder().encode(macDirectory.ledger)
            try data.write(to: Self.ownedRecordLedgerURL(supportDirectory: fastTabSupportDirectory), options: .atomic)
        } catch {
            logger.error("Failed to save the Mac state directory ledger: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Ledger inputs

    /// Save / delete acknowledgements (and deletions seen in the fetch feed) for
    /// this Mac's own StateZone records.
    func noteDirectoryAcks(saved: [CKRecord.ID], deleted: [CKRecord.ID]) {
        let savedNames = ownStateRecordNames(saved)
        let deletedNames = ownStateRecordNames(deleted)
        guard !savedNames.isEmpty || !deletedNames.isEmpty else { return }
        var ledger = macDirectory.ledger
        ledger.noteSaved(savedNames)
        ledger.noteDeleted(deletedNames)
        macDirectory.ledger = ledger
        scheduleDirectoryWrite()
    }

    private func ownStateRecordNames(_ recordIDs: [CKRecord.ID]) -> [String] {
        recordIDs
            .filter { $0.zoneID == SyncConstants.stateZoneID }
            .map(\.recordName)
            .filter { MacStateDirectory.isOwnedStateRecordName($0, deviceID: deviceID) }
    }

    /// Wraps a state-zone mirror catch-up: the mirror's view of this Mac's records
    /// becomes the ledger (covers records published before the ledger existed, and
    /// any ack this Mac missed), keeping acks that landed while it ran.
    func resyncDirectoryLedger(around catchUp: () async throws -> Void) async throws {
        macDirectory.ledger.beginResync()
        do {
            try await catchUp()
        } catch {
            macDirectory.ledger.cancelResync()
            throw error
        }
        let serverNames = Set(stateZoneMirror.recordsByName.keys).union(stateZoneMirror.unreadableRecordNames)
        macDirectory.ledger.finishResync(serverRecordNames: serverNames.filter {
            MacStateDirectory.isOwnedStateRecordName($0, deviceID: deviceID)
        })
        scheduleDirectoryWrite()
    }

    /// The engine's own fetch brings the shared record back after other Macs write it.
    func retainDirectoryServerRecord(_ record: CKRecord) {
        guard record.recordID == MacStateDirectory.recordID,
              record.recordType == MacStateDirectory.recordType else { return }
        macDirectory.serverRecord = record
    }

    /// Account change: the new account has its own directory and records.
    func resetMacDirectoryState() {
        macDirectory.writeTask?.cancel()
        macDirectory = MacDirectoryPublishState()
    }

    // MARK: - Writing

    private func desiredDirectoryEntry(now: Date) -> MacStateDirectoryEntry {
        MacStateDirectoryEntry(
            deviceID: deviceID,
            deviceName: deviceName,
            lastSeenAt: now,
            recordNames: macDirectory.ledger.recordNames
        )
    }

    private func needsDirectoryWrite(now: Date) -> Bool {
        MacStateDirectory.shouldWrite(published: macDirectory.publishedEntry, desired: desiredDirectoryEntry(now: now), now: now)
    }

    /// Safe to call often (every poll tick, every ack): at most one write is
    /// pending, writes are spaced by `MacStateDirectory.minimumWriteSpacing`, and
    /// nothing is written unless the entry changed or the liveness refresh is due.
    func scheduleDirectoryWrite() {
        guard syncEngine != nil, macDirectory.writeTask == nil else { return }
        let now = Date()
        guard needsDirectoryWrite(now: now) else { return }
        let delay = MacStateDirectory.writeDelay(
            lastWriteAt: macDirectory.lastWriteAt,
            retryAfter: macDirectory.retryAfter,
            now: now
        )
        macDirectory.writeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(delay, 0) * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            await self.writeDirectoryIfNeeded()
            guard !Task.isCancelled else { return }
            self.macDirectory.writeTask = nil
            // Acks that arrived during the write, or a failure's retry.
            self.scheduleDirectoryWrite()
        }
    }

    private func writeDirectoryIfNeeded() async {
        let now = Date()
        let desired = desiredDirectoryEntry(now: now)
        guard MacStateDirectory.shouldWrite(published: macDirectory.publishedEntry, desired: desired, now: now) else { return }

        var base = macDirectory.serverRecord ?? MacStateDirectory.newRecord()
        var lastError: Error?
        attempts: for _ in 0..<4 {
            // Merge onto the server copy: other Macs' entries survive, ours is replaced.
            let merged = (MacStateDirectory(from: base) ?? MacStateDirectory()).merging(desired, now: now)
            guard let record = merged.applying(to: base) else {
                logger.error("Mac state directory: could not encode \(desired.recordNames.count) records")
                return
            }
            do {
                let saved = try await saveDirectoryRecord(record)
                // Account switched mid-save (`resetMacDirectoryState` cancelled us):
                // this result belongs to the previous account's state.
                guard !Task.isCancelled else { return }
                macDirectory.serverRecord = saved
                macDirectory.publishedEntry = desired
                macDirectory.lastWriteAt = now
                macDirectory.retryAfter = nil
                macDirectory.failures = 0
                logger.notice("Mac state directory written: \(desired.recordNames.count) records, \(merged.entries.count) Macs")
                return
            } catch {
                // Account switched mid-save: not a failure of this Mac's directory.
                guard !Task.isCancelled else { return }
                lastError = error
                switch (error as? CKError)?.code {
                case .serverRecordChanged:
                    // Another Mac wrote it, or our first insert met an existing record.
                    guard let serverRecord = (error as? CKError)?.serverRecord else { break attempts }
                    base = serverRecord
                case .unknownItem:
                    base = MacStateDirectory.newRecord()
                case .zoneNotFound, .userDeletedZone:
                    do {
                        _ = try await database.modifyRecordZones(
                            saving: [CKRecordZone(zoneID: MacStateDirectory.zoneID)], deleting: [])
                    } catch {
                        lastError = error
                        break attempts
                    }
                    base = MacStateDirectory.newRecord()
                default:
                    break attempts
                }
            }
        }
        guard !Task.isCancelled else { return }
        macDirectory.failures += 1
        let backoff = MacStateDirectory.retryBackoff(afterFailures: macDirectory.failures)
        macDirectory.retryAfter = now.addingTimeInterval(backoff)
        macDirectory.serverRecord = nil
        logger.error("Mac state directory write failed (attempt \(self.macDirectory.failures), next in \(Int(backoff))s): \(lastError?.localizedDescription ?? "conflicts kept recurring", privacy: .public)")
    }

    private func saveDirectoryRecord(_ record: CKRecord) async throws -> CKRecord {
        do {
            let (saveResults, _) = try await database.modifyRecords(
                saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
            guard let result = saveResults[record.recordID] else { throw CKError(.internalError) }
            return try result.get()
        } catch let error as CKError where error.code == .partialFailure {
            // Surface the record's own error so the conflict handling above sees it.
            throw (error.partialErrorsByItemID?[record.recordID] as? CKError) ?? error
        }
    }
}
