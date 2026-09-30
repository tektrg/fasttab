import Foundation
import CloudKit
import FastTabSync

// CloudKit side of `StateZoneMirror`: one change-feed page per call, reduced
// to the fields the mirror's readers (reconcile, sync probe, phone pickup)
// need. Read-only: never touches CKSyncEngine's token or the publish ledger.

extension SyncService {
    /// Tab identity + URL (reconcile, probe) and every device field
    /// (`PairedPhoneStore`). Leaves out bookmark and history payloads, which
    /// dominate the zone's bytes. A partial `SyncedTab` is still a safe base
    /// for `serverRecordsByID`: `SyncedTab.applying(to:)` rewrites every field.
    nonisolated private static let stateZoneMirrorDesiredKeys: [CKRecord.FieldKey] =
        ["browserName", "url"] + SyncedDevice.recordFieldKeys

    func makeStateZoneMirror() -> StateZoneMirror<CKServerChangeToken> {
        StateZoneMirror(
            fetchPage: { [unowned self] token in try await self.fetchStateZoneChangePage(since: token) },
            isTokenExpired: { ($0 as? CKError)?.code == .changeTokenExpired }
        )
    }

    /// Catches the shared mirror up and logs what it cost. Throws what the
    /// feed threw; callers decide what a failure means for them.
    func catchUpStateZoneMirror(reason: String) async throws {
        let startedAt = Date()
        let summary = try await stateZoneMirror.catchUp()
        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        logger.info("State-zone mirror caught up for \(reason, privacy: .public): pages=\(summary.pageCount) fullWalk=\(summary.wasFullWalk) elapsedMs=\(elapsedMs) records=\(self.stateZoneMirror.recordsByName.count) unreadable=\(self.stateZoneMirror.unreadableRecordNames.count)")
    }

    private func fetchStateZoneChangePage(
        since token: CKServerChangeToken?
    ) async throws -> StateZoneMirror<CKServerChangeToken>.Page {
        let zoneChanges = try await database.recordZoneChanges(
            inZoneWith: SyncConstants.stateZoneID,
            since: token,
            desiredKeys: Self.stateZoneMirrorDesiredKeys
        )
        var modifiedRecords: [CKRecord] = []
        var unreadableRecordNames: [String] = []
        for (recordID, modificationResult) in zoneChanges.modificationResultsByID {
            switch modificationResult {
            case .success(let modification): modifiedRecords.append(modification.record)
            case .failure: unreadableRecordNames.append(recordID.recordName)
            }
        }
        return StateZoneMirror.Page(
            modifiedRecords: modifiedRecords,
            unreadableRecordNames: unreadableRecordNames,
            deletedRecordNames: zoneChanges.deletions.map(\.recordID.recordName),
            token: zoneChanges.changeToken,
            moreComing: zoneChanges.moreComing
        )
    }
}
