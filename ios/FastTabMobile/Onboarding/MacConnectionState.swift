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

    /// "✓ Found Trung's MacBook · 42 tabs"
    static func foundLabel(macName: String, tabCount: Int) -> String {
        let tabs = tabCount == 1 ? "1 tab" : "\(tabCount) tabs"
        return "Found \(macName) · \(tabs)"
    }
}
