import Foundation

/// Pure rules for "which devices are paired with which", shared by both apps.
///
/// Both apps publish a `SyncedDevice` record into the same state zone, so every
/// reader sees Macs *and* phones. These functions are the one place that
/// decides what each side does with that mixed list.
public enum SyncedDevicePairing {
    /// How often each app republishes its own device record while it runs.
    /// The phone's freshness banner derives its thresholds from this, so a
    /// change here changes what "Active now" means on the phone.
    public static let heartbeatInterval: TimeInterval = 3 * 60

    /// How long after its last heartbeat a phone still counts as paired. The
    /// phone only publishes while it is open, so "connected" means "has used
    /// FastTab on this iCloud account lately", not "is on screen right now".
    /// A reinstalled phone gets a new device id, so this window is also what
    /// retires the old install's record from the Mac's view.
    public static let phonePairingWindow: TimeInterval = 30 * 24 * 60 * 60

    public static func isHeartbeatDue(
        lastPublishedAt: Date?,
        now: Date,
        interval: TimeInterval = heartbeatInterval
    ) -> Bool {
        guard let lastPublishedAt else { return true }
        return now.timeIntervalSince(lastPublishedAt) >= interval
    }

    /// Phones that have checked in within the pairing window, most recent first.
    /// Macs — this one included — are never phones.
    public static func pairedPhones(
        in devices: [SyncedDevice],
        now: Date,
        window: TimeInterval = phonePairingWindow
    ) -> [SyncedDevice] {
        devices
            .filter { !$0.isMac && now.timeIntervalSince($0.lastSeenAt) < window }
            .sorted { $0.lastSeenAt > $1.lastSeenAt }
    }
}
