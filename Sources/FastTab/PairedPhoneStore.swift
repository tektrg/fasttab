import Foundation
import CloudKit
import Combine
import FastTabSync

/// The iPhones that have checked in over iCloud sync — what Settings > Sync and
/// the onboarding iPhone step read to say "iPhone connected".
///
/// Persisted, because the phone only publishes its device record while it is
/// open: after a Mac relaunch, CKSyncEngine's change token is already past the
/// phone's last heartbeat, so an in-memory list would forget a paired phone
/// until the user happened to open the app again.
///
/// Deliberately independent of `SyncService` (no `CKContainer`), so views and
/// tests can hold it without constructing CloudKit.
@MainActor
final class PairedPhoneStore: ObservableObject {
    static let shared = PairedPhoneStore()

    /// Phones only — Macs, this one included, are dropped on the way in.
    @Published private(set) var phones: [SyncedDevice]

    private let defaults: UserDefaults
    private static let defaultsKey = "FastTab.PairedPhones"

    init(defaults: UserDefaults = .standard, now: Date = Date()) {
        self.defaults = defaults
        let stored = (defaults.data(forKey: Self.defaultsKey))
            .flatMap { try? JSONDecoder().decode([SyncedDevice].self, from: $0) } ?? []
        self.phones = SyncedDevicePairing.pairedPhones(in: stored, now: now)
    }

    /// Most recently seen paired phone, if any.
    func mostRecentPhone(now: Date = Date()) -> SyncedDevice? {
        SyncedDevicePairing.pairedPhones(in: phones, now: now).first
    }

    /// Takes any fetched records; keeps only phone device records.
    func absorb(_ records: [CKRecord], now: Date = Date()) {
        let devices = records.compactMap(SyncedDevice.init(from:))
        guard !devices.isEmpty else { return }
        record(devices, now: now)
    }

    func record(_ devices: [SyncedDevice], now: Date = Date()) {
        var byID = Dictionary(uniqueKeysWithValues: phones.map { ($0.id, $0) })
        for device in devices where !device.isMac {
            // Newest heartbeat wins; a full zone re-read can hand back an
            // older copy than a record the change feed already delivered.
            if let known = byID[device.id], known.lastSeenAt > device.lastSeenAt { continue }
            byID[device.id] = device
        }
        replace(with: Array(byID.values), now: now)
    }

    func forget(recordNames: [String], now: Date = Date()) {
        guard !recordNames.isEmpty else { return }
        let removed = Set(recordNames)
        replace(with: phones.filter { !removed.contains($0.id) }, now: now)
    }

    private func replace(with devices: [SyncedDevice], now: Date) {
        let paired = SyncedDevicePairing.pairedPhones(in: devices, now: now)
        guard paired != phones else { return }
        phones = paired
        if let data = try? JSONEncoder().encode(paired) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
