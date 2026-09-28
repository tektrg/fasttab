import Testing
import CloudKit
import Foundation
@testable import FastTab
@testable import FastTabSync

/// Two-way pairing: both apps publish `SyncedDevice` records into one zone, so
/// each side must classify what it reads — the phone keeps only Macs as "the
/// Mac", and the Mac keeps only phones as "paired iPhones".
@Suite("Device pairing")
struct DevicePairingTests {
    private let zoneID = CKRecordZone.ID(zoneName: "StateZone", ownerName: CKCurrentUserDefaultName)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func device(_ id: String, kind: SyncedDeviceKind, secondsAgo: TimeInterval = 60) -> SyncedDevice {
        SyncedDevice(id: id, name: id, modelName: "m", lastSeenAt: now.addingTimeInterval(-secondsAgo), appVersion: "1", kind: kind)
    }

    // MARK: Record compatibility

    @Test("Kind round-trips through a CloudKit record")
    func kindRoundTrips() throws {
        let phone = device("phone", kind: .iphone)
        let decoded = try #require(SyncedDevice(from: phone.toRecord(zoneID: zoneID)))
        #expect(decoded.kind == .iphone)
        #expect(!decoded.isMac)
    }

    @Test("A record from an old build (no kind field) is a Mac")
    func legacyRecordIsMac() throws {
        let record = device("old-mac", kind: .mac).toRecord(zoneID: zoneID)
        record[SyncedDevice.kindRecordKey] = nil
        let decoded = try #require(SyncedDevice(from: record))
        #expect(decoded.kind == .mac)
    }

    @Test("An unknown future kind decodes but is never a Mac")
    func unknownKindIsNotMac() throws {
        let record = device("tablet", kind: .mac).toRecord(zoneID: zoneID)
        record[SyncedDevice.kindRecordKey] = "ipad" as NSString
        let decoded = try #require(SyncedDevice(from: record))
        #expect(decoded.kind.rawValue == "ipad")
        #expect(!decoded.isMac)
    }

    @Test("A cached device saved before kind existed still decodes, as a Mac")
    func legacyCacheJSONDecodes() throws {
        let json = #"{"id":"mac-1","name":"Mac","modelName":"MacBook","lastSeenAt":0,"appVersion":"1.0"}"#
        let decoded = try JSONDecoder().decode(SyncedDevice.self, from: Data(json.utf8))
        #expect(decoded.kind == .mac)
        let reencoded = try JSONDecoder().decode(SyncedDevice.self, from: JSONEncoder().encode(device("p", kind: .iphone)))
        #expect(reencoded.kind == .iphone)
    }

    // MARK: Classification

    @Test("pairedPhones keeps recent non-Macs, newest first")
    func pairedPhonesFilterAndOrder() {
        let window = SyncedDevicePairing.phonePairingWindow
        let devices = [
            device("mac", kind: .mac, secondsAgo: 10),
            device("older-phone", kind: .iphone, secondsAgo: 3_600),
            device("newer-phone", kind: .iphone, secondsAgo: 60),
            device("retired-phone", kind: .iphone, secondsAgo: window + 1),
        ]
        #expect(SyncedDevicePairing.pairedPhones(in: devices, now: now).map(\.id) == ["newer-phone", "older-phone"])
    }

    @Test("Heartbeat is due at the interval, and immediately when never sent")
    func heartbeatDue() {
        let interval = SyncedDevicePairing.heartbeatInterval
        #expect(SyncedDevicePairing.isHeartbeatDue(lastPublishedAt: nil, now: now))
        #expect(!SyncedDevicePairing.isHeartbeatDue(lastPublishedAt: now.addingTimeInterval(-interval + 1), now: now))
        #expect(SyncedDevicePairing.isHeartbeatDue(lastPublishedAt: now.addingTimeInterval(-interval), now: now))
    }

    // MARK: Mac-side store

    @MainActor
    private func makeStore() -> (PairedPhoneStore, UserDefaults) {
        let defaults = UserDefaults(suiteName: "DevicePairingTests.\(UUID().uuidString)")!
        return (PairedPhoneStore(defaults: defaults, now: now), defaults)
    }

    @Test("Store keeps phones only, and survives a relaunch")
    @MainActor
    func storeKeepsPhonesAndPersists() {
        let (store, defaults) = makeStore()
        store.absorb([
            device("this-mac", kind: .mac).toRecord(zoneID: zoneID),
            device("phone", kind: .iphone).toRecord(zoneID: zoneID),
        ], now: now)
        #expect(store.phones.map(\.id) == ["phone"])

        let relaunched = PairedPhoneStore(defaults: defaults, now: now)
        #expect(relaunched.phones.map(\.id) == ["phone"])
        #expect(relaunched.mostRecentPhone(now: now)?.id == "phone")
    }

    @Test("An older copy from a full re-read never rolls lastSeen back")
    @MainActor
    func storeKeepsNewestHeartbeat() {
        let (store, _) = makeStore()
        store.record([device("phone", kind: .iphone, secondsAgo: 60)], now: now)
        store.record([device("phone", kind: .iphone, secondsAgo: 3_600)], now: now)
        #expect(store.phones.first?.lastSeenAt == now.addingTimeInterval(-60))
    }

    @Test("A deleted phone record is forgotten; a stale phone ages out")
    @MainActor
    func storeForgetsAndAgesOut() {
        let (store, _) = makeStore()
        store.record([device("phone", kind: .iphone)], now: now)
        store.forget(recordNames: ["phone"], now: now)
        #expect(store.phones.isEmpty)

        store.record([device("phone", kind: .iphone)], now: now)
        #expect(store.mostRecentPhone(now: now.addingTimeInterval(SyncedDevicePairing.phonePairingWindow)) == nil)
    }

    @Test("Settings line names the phone and its age")
    func settingsLine() {
        let phone = device("iPhone", kind: .iphone, secondsAgo: 120)
        #expect(SyncStatusPresentation.pairedPhoneLine(phone, now: now) == "iPhone · last seen 2m ago")
    }
}
