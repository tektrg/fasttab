import XCTest
import CloudKit
import FastTabSync
@testable import FastTabMobile

/// Two-way pairing, phone side: the phone publishes its own device record, and
/// must never mistake it (or any other phone) for "the Mac".
@MainActor
final class DevicePairingTests: XCTestCase {
    private func temporaryCache() -> LocalCache {
        LocalCache(customFileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("pairing-\(UUID().uuidString).json"))
    }

    private func device(_ id: String, kind: SyncedDeviceKind) -> SyncedDevice {
        SyncedDevice(id: id, name: id, modelName: "m", appVersion: "1", kind: kind)
    }

    // MARK: "The Mac" stays a Mac

    func testPhoneRecordArrivingFirstNeverBecomesTheMac() {
        let cache = temporaryCache()
        cache.updateDevice(device("this-phone", kind: .iphone))
        cache.updateDevice(device("other-phone", kind: .iphone))
        cache.updateDevice(device("mac", kind: .mac))
        XCTAssertEqual(cache.state.devices.map(\.id), ["mac"])
        XCTAssertEqual(cache.state.devices.first?.id, "mac")
    }

    func testUnknownFutureKindIsNotTreatedAsTheMac() {
        let cache = temporaryCache()
        cache.updateDevice(device("tablet", kind: SyncedDeviceKind(rawValue: "ipad")))
        XCTAssertTrue(cache.state.devices.isEmpty)
    }

    func testRecordFromOldMacBuildWithoutKindIsStillTheMac() throws {
        let record = device("old-mac", kind: .mac).toRecord(zoneID: SyncConstants.stateZoneID)
        record["deviceKind"] = nil
        let cache = temporaryCache()
        cache.updateDevice(try XCTUnwrap(SyncedDevice(from: record)))
        XCTAssertEqual(cache.state.devices.map(\.id), ["old-mac"])
    }

    // MARK: Heartbeat record

    func testOwnDeviceIsAnIPhoneWithAName() {
        let own = SyncConsumer.ownDevice(id: "p", name: "", modelName: "iPhone", appVersion: "1", lastSeenAt: Date())
        XCTAssertEqual(own.kind, .iphone)
        XCTAssertEqual(own.name, "iPhone")
    }

    func testHeartbeatUpdatesTheServerCopyInPlace() {
        let own = SyncConsumer.ownDevice(id: "p", name: "iPhone", modelName: "iPhone", appVersion: "2", lastSeenAt: Date())
        let server = SyncConsumer.ownDevice(id: "p", name: "iPhone", modelName: "iPhone", appVersion: "1", lastSeenAt: .distantPast)
            .toRecord(zoneID: SyncConstants.stateZoneID)

        XCTAssertTrue(SyncConsumer.heartbeatRecord(for: own, serverRecord: server) === server)
        XCTAssertEqual(server["appVersion"] as? String, "2")
        XCTAssertEqual(server["deviceKind"] as? String, "iphone")

        let fresh = SyncConsumer.heartbeatRecord(for: own, serverRecord: nil)
        XCTAssertEqual(fresh.recordID, CKRecord.ID(recordName: "p", zoneID: SyncConstants.stateZoneID))
    }

    func testOnlyThisPhonesRecordIsRetained() {
        let mine = device("p", kind: .iphone).toRecord(zoneID: SyncConstants.stateZoneID)
        let mac = device("mac", kind: .mac).toRecord(zoneID: SyncConstants.stateZoneID)
        XCTAssertTrue(SyncConsumer.isOwnDeviceRecord(mine, deviceID: "p"))
        XCTAssertFalse(SyncConsumer.isOwnDeviceRecord(mac, deviceID: "p"))
    }

    // MARK: Conflict retry

    func testHeartbeatConflictReappliesOntoServerCopy() throws {
        let intended = device("p", kind: .iphone).toRecord(zoneID: SyncConstants.stateZoneID)
        let server = SyncedDevice(id: "p", name: "old", modelName: "m", lastSeenAt: .distantPast, appVersion: "0", kind: .iphone)
            .toRecord(zoneID: SyncConstants.stateZoneID)
        let error = CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: server])

        let retry = try XCTUnwrap(SyncConsumer.recordForRetry(intendedRecord: intended, error: error))
        XCTAssertTrue(retry === server)
        XCTAssertEqual(retry["name"] as? String, "p")
    }

    func testDeletedHeartbeatIsReinsertedButCommandsAreNot() {
        let heartbeat = device("p", kind: .iphone).toRecord(zoneID: SyncConstants.stateZoneID)
        let command = SyncCommand(kind: .openOnMac, targetDeviceID: "mac", sourceDeviceName: "iPhone", payloadJSON: "{}")
            .toRecord(zoneID: SyncConstants.commandsZoneID)
        let missing = CKError(.unknownItem)

        XCTAssertEqual(SyncConsumer.recordForRetry(intendedRecord: heartbeat, error: missing)?.recordID, heartbeat.recordID)
        XCTAssertNil(SyncConsumer.recordForRetry(intendedRecord: command, error: missing))
    }
}
