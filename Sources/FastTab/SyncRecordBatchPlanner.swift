import Foundation
import CloudKit

/// Decides what actually goes into a `CKSyncEngine` send batch.
///
/// `CKSyncEngine` persists the *fact* that a record change is pending, but asks
/// the app for the record's content at send time. Our content cache is in
/// memory only, so after a relaunch a restored pending save can have no record
/// behind it. Returning `nil` from the record provider in that situation drops
/// the change with no error anywhere — a silent void. This planner separates the
/// deliverable changes from the unbacked ones so the caller can drop the latter
/// deliberately, and log it.
enum SyncRecordBatchPlanner {
    struct Plan: Equatable {
        var deliverableChanges: [CKSyncEngine.PendingRecordZoneChange]
        /// Pending saves with no cached record content. These must be removed
        /// from the sync engine's state, or they are retried forever.
        var stalePendingSaves: [CKSyncEngine.PendingRecordZoneChange]
    }

    static func plan(
        pendingChanges: [CKSyncEngine.PendingRecordZoneChange],
        availableRecordIDs: Set<CKRecord.ID>
    ) -> Plan {
        var deliverableChanges: [CKSyncEngine.PendingRecordZoneChange] = []
        var stalePendingSaves: [CKSyncEngine.PendingRecordZoneChange] = []

        for change in pendingChanges {
            switch change {
            case .saveRecord(let recordID) where !availableRecordIDs.contains(recordID):
                stalePendingSaves.append(change)
            default:
                // Deletes need no record content, so they are always deliverable.
                deliverableChanges.append(change)
            }
        }

        return Plan(deliverableChanges: deliverableChanges, stalePendingSaves: stalePendingSaves)
    }
}
