import Foundation
import FastTabSync

extension CachedSyncState {
    /// The Mac this iPhone syncs with, if any has ever been seen.
    var connectedMac: SyncedDevice? { SyncedDevicePairing.mostRecentMac(in: devices) }
}

/// What the "Connect your Mac" step says, from live sync facts.
///
/// Order matters: a blocked iCloud account outranks everything (nothing can sync
/// until it is fixed), then a found Mac, then "still looking" until the wait runs
/// out, then the install hint.
enum MacConnectionState: Equatable {
    case signedOut
    case restricted
    case searching
    case found(macName: String, tabCount: Int)
    case notFound

    /// How long "Looking for your Mac…" runs before the install hint appears.
    /// A signed-in Mac's device record normally arrives within a few seconds.
    static let searchPatience: Duration = .seconds(20)

    static func resolve(
        health: SyncHealth,
        devices: [SyncedDevice],
        tabs: [SyncedTab],
        hasWaitedLongEnough: Bool
    ) -> MacConnectionState {
        switch health {
        case .noAccount: return .signedOut
        case .restricted: return .restricted
        case .unknown, .ok, .failing: break
        }
        if let mac = SyncedDevicePairing.mostRecentMac(in: devices) {
            let tabCount = tabs.filter { $0.deviceID == mac.id }.count
            return .found(macName: mac.name, tabCount: tabCount)
        }
        return hasWaitedLongEnough ? .notFound : .searching
    }

    var isFound: Bool {
        if case .found = self { return true }
        return false
    }

    /// Line under "Found …". A Mac silent for a day or more is still the paired
    /// Mac, but its tabs are old: say so, matching the Read/Tabs warning banner
    /// (`SyncWarningPolicy`) that opened this screen.
    static func foundDetail(mac: SyncedDevice?, now: Date = Date()) -> String {
        let freshness = SyncStatusCopy.macFreshness(device: mac, now: now)
        guard mac != nil, freshness.isOffline else {
            return "Your Mac's tabs and bookmarks are on this iPhone."
        }
        return "\(freshness.text). Open FastTab on your Mac to bring its tabs up to date."
    }

    /// "✓ Found Trung's MacBook · 42 tabs"
    static func foundLabel(macName: String, tabCount: Int) -> String {
        let tabs = tabCount == 1 ? "1 tab" : "\(tabCount) tabs"
        return "Found \(macName) · \(tabs)"
    }
}
