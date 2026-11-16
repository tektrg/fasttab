import Foundation
import CloudKit
import FastTabSync

// The history-free fast path (`MacStateDirectory`, FastTabSync). Learning what is in
// StateZone from its change history means paging through every past change the Mac
// ever made there (minutes on a fresh install, and the phone only syncs while on
// screen), so a new phone said "can't connect to a Mac" long after the Mac was
// heartbeating. Each Mac now lists its live records in one fixed-ID record; this
// fetches that list and the listed records by ID — seconds, no history.
//
// The history sync keeps running underneath and stays the authority:
// - it deletes anything; this path removes only records it alone has shown, once a
//   newer directory stops listing them (closed tabs on a fresh install), and
// - `DirectSnapshotPrecedence` refuses a direct copy that is older than what is
//   shown, or of a record the history sync deleted.

extension SyncConsumer {
    /// Poll-tick entry: at most once per `MacDirectoryFetchPlan.checkInterval`.
    func refreshFromMacDirectoryIfDue() async {
        guard ZoneSweepSchedule.isDue(
            lastSweptAt: lastMacDirectoryCheckAt, now: Date(), interval: MacDirectoryFetchPlan.checkInterval
        ) else { return }
        await refreshFromMacDirectory()
    }

    /// Fetches the directory, then the listed records: all of them until one full
    /// pass has succeeded this launch, afterwards only records not fetched yet plus
    /// each Mac's device record (its "last seen").
    func refreshFromMacDirectory() async {
        guard !macDirectoryCheckInFlight else { return }
        macDirectoryCheckInFlight = true
        defer { macDirectoryCheckInFlight = false }
        lastMacDirectoryCheckAt = Date()
        let startedAt = Date()
        let full = !hasFullMacDirectorySnapshot

        let directory: MacStateDirectory
        let directoryModifiedAt: Date?
        do {
            let results = try await database.records(for: [MacStateDirectory.recordID])
            guard let result = results[MacStateDirectory.recordID] else { return }
            let directoryRecord = try result.get()
            directoryModifiedAt = directoryRecord.modificationDate
            guard let decoded = MacStateDirectory(from: directoryRecord) else {
                traceMacDirectoryProblem("record unreadable")
                return
            }
            directory = decoded
            lastMacDirectoryProblem = nil
        } catch {
            guard !ZoneSweepSchedule.isCancellation(error) else { return }
            if let code = (error as? CKError)?.code, code == .unknownItem || code == .zoneNotFound {
                // No Mac on a build that writes it yet; the history sync still works.
                traceMacDirectoryProblem("none yet (\(Self.describe(error)))")
            } else {
                traceMacDirectoryProblem("fetch failed: \(Self.describe(error))")
            }
            return
        }

        let names = MacDirectoryFetchPlan.recordNames(
            in: directory, alreadyFetched: directlyFetchedRecordNames, full: full)
        var fetched: [CKRecord] = []
        var missingNames: [String] = []
        var failures: [String] = []
        var batchFailed = false
        for batch in MacDirectoryFetchPlan.batches(names) {
            let ids = batch.map { CKRecord.ID(recordName: $0, zoneID: SyncConstants.stateZoneID) }
            do {
                for (recordID, result) in try await database.records(for: ids) {
                    switch result {
                    case .success(let record):
                        fetched.append(record)
                    case .failure(let error) where (error as? CKError)?.code == .unknownItem:
                        // Deleted since the Mac last wrote its list: nothing to show.
                        missingNames.append(recordID.recordName)
                    case .failure(let error):
                        failures.append("\(recordID.recordName): \(Self.describe(error))")
                    }
                }
            } catch {
                guard !ZoneSweepSchedule.isCancellation(error) else { return }
                failures.append("batch of \(batch.count): \(Self.describe(error))")
                batchFailed = true
                break
            }
        }

        // One MainActor turn from here, after the last await: a history delete that
        // landed while these fetches were in flight is already known to the precedence.
        let admitted = fetched.filter {
            directSnapshotPrecedence.admitsDirect(recordName: $0.recordID.recordName, modifiedAt: $0.modificationDate)
        }
        let dropped = directSnapshotPrecedence.directOnlyNamesDropped(
            by: directory, directoryModifiedAt: directoryModifiedAt)
        applyRecordsToCache(
            modifications: admitted,
            deletions: dropped.map { CKRecord.ID(recordName: $0, zoneID: SyncConstants.stateZoneID) })
        directSnapshotPrecedence.forgetDirectOnly(dropped)
        directlyFetchedRecordNames.subtract(dropped)
        for record in admitted {
            directSnapshotPrecedence.noteDirectApplied(
                recordName: record.recordID.recordName, modifiedAt: record.modificationDate)
        }
        LocalCache.shared.flushPendingSave()
        directlyFetchedRecordNames.formUnion(fetched.map(\.recordID.recordName))
        directlyFetchedRecordNames.formUnion(missingNames)
        // Only a failed request keeps the next pass full: one record that keeps failing
        // must not re-download every bookmark and history record every 30 s.
        if !batchFailed { hasFullMacDirectorySnapshot = true }
        if !admitted.isEmpty || !dropped.isEmpty {
            fetchedChangeGeneration += 1
        }

        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        if full || !admitted.isEmpty || !dropped.isEmpty || !failures.isEmpty {
            Self.syncTrace("directory: \(full ? "full" : "light") macs=\(directory.entries.count) requested=\(names.count) fetched=\(fetched.count) applied=\(admitted.count) dropped=\(dropped.count) missing=\(missingNames.count) failed=\(failures.count) elapsedMs=\(elapsedMs)")
        }
        for failure in failures.prefix(5) {
            Self.syncTrace("directory: record fetch failed: \(failure)")
        }
    }

    private func traceMacDirectoryProblem(_ problem: String) {
        guard problem != lastMacDirectoryProblem else { return }
        lastMacDirectoryProblem = problem
        Self.syncTrace("directory: \(problem)")
    }

    /// A different iCloud account has a different directory and records.
    func resetMacDirectorySnapshot() {
        directSnapshotPrecedence.reset()
        directlyFetchedRecordNames.removeAll()
        hasFullMacDirectorySnapshot = false
        lastMacDirectoryCheckAt = nil
        lastMacDirectoryProblem = nil
    }

    /// History-path bookkeeping for `DirectSnapshotPrecedence`: called for every
    /// engine fetch and zone sweep before their records reach the cache.
    func noteHistoryChangesForDirectSnapshot(modifications: [CKRecord], deletions: [CKRecord.ID]) {
        let modified = modifications
            .filter { $0.recordID.zoneID == SyncConstants.stateZoneID }
            .map { (name: $0.recordID.recordName, modifiedAt: $0.modificationDate) }
        let deleted = deletions
            .filter { $0.zoneID == SyncConstants.stateZoneID }
            .map(\.recordName)
        guard !modified.isEmpty || !deleted.isEmpty else { return }
        directSnapshotPrecedence.noteHistoryApplied(modified: modified, deleted: deleted)
    }

    // MARK: - Diagnostics

    /// Debug builds: sync steps and errors in Documents/reader-sync.log (beside the
    /// reader trace), so a phone that shows no Mac can be diagnosed afterwards
    /// without the app on screen. Release builds write nothing.
    nonisolated static func syncTrace(_ message: @autoclosure () -> String) {
        #if DEBUG
        readerTrace("sync: \(message())")
        #endif
    }

    nonisolated static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)"
    }
}
