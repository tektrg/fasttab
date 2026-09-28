import Foundation
import CloudKit
import UIKit
import FastTabSync

// Two-way pairing: the phone publishes its own `SyncedDevice` record (kind
// `.iphone`) so the Mac can show "iPhone connected · last seen 2m ago".
//
// Unlike commands, the heartbeat needs no durable outbox: its content is
// re-derivable at any moment, and it is re-queued on every launch/foreground
// before the first send, so the record provider always has a body for it.

extension SyncConsumer {
    /// Queues a fresh heartbeat. Sending is left to the caller's next send
    /// (foreground refresh or poll) so a heartbeat never raises the "Syncing…"
    /// indicator on its own.
    func publishOwnDevice(at publishedAt: Date = Date()) {
        guard let syncEngine else { return }
        let device = Self.ownDevice(
            id: deviceID,
            name: deviceName,
            modelName: UIDevice.current.model,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0",
            lastSeenAt: publishedAt
        )
        let record = Self.heartbeatRecord(for: device, serverRecord: ownDeviceServerRecord)
        pendingRecordsToSave[record.recordID] = record
        lastDevicePublishAt = publishedAt
        syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
    }

    /// The foreground poll runs every few seconds; the heartbeat only needs to
    /// land every `SyncedDevicePairing.heartbeatInterval`.
    func publishOwnDeviceIfDue(now: Date = Date()) {
        guard SyncedDevicePairing.isHeartbeatDue(lastPublishedAt: lastDevicePublishAt, now: now) else { return }
        publishOwnDevice(at: now)
    }

    /// Keeps the server's change tag for this phone's own device record, from a
    /// save ack, a fetch, or a conflict retry.
    func retainOwnDeviceRecordIfMine(_ record: CKRecord) {
        guard Self.isOwnDeviceRecord(record, deviceID: deviceID) else { return }
        ownDeviceServerRecord = record
    }

    // MARK: - Pure helpers

    nonisolated static func ownDevice(
        id: String,
        name: String,
        modelName: String,
        appVersion: String,
        lastSeenAt: Date
    ) -> SyncedDevice {
        SyncedDevice(
            id: id,
            name: name.isEmpty ? "iPhone" : name,
            modelName: modelName,
            lastSeenAt: lastSeenAt,
            appVersion: appVersion,
            kind: .iphone
        )
    }

    /// Builds on the server copy when there is one; a blind insert over an
    /// existing record fails with "record to insert already exists".
    nonisolated static func heartbeatRecord(for device: SyncedDevice, serverRecord: CKRecord?) -> CKRecord {
        if let serverRecord,
           serverRecord.recordType == SyncedDevice.recordType,
           serverRecord.recordID.recordName == device.id,
           serverRecord.recordID.zoneID == SyncConstants.stateZoneID {
            return device.applying(to: serverRecord)
        }
        return device.toRecord(zoneID: SyncConstants.stateZoneID)
    }

    nonisolated static func isOwnDeviceRecord(_ record: CKRecord, deviceID: String) -> Bool {
        record.recordType == SyncedDevice.recordType
            && record.recordID.recordName == deviceID
            && record.recordID.zoneID == SyncConstants.stateZoneID
    }
}
