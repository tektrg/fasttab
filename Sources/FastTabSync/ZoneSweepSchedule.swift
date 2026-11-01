import Foundation

/// Pure rules for the iPhone's manual iCloud sweep.
///
/// `CKSyncEngine.fetchChanges()` only fetches a zone after a CloudKit push marked
/// it dirty, and pushes do not reliably reach either app. The phone therefore also
/// reads each zone itself on a timer (token-based, so only what changed). These
/// two rules are kept here so they can be unit-tested without a simulator.
public enum ZoneSweepSchedule {
    /// How often the on-screen phone sweeps. The foreground poll ticks every few
    /// seconds; a CloudKit read that often would be throttled, and the Mac's
    /// heartbeat only changes every `SyncedDevicePairing.heartbeatInterval`.
    public static let interval: TimeInterval = 30

    public static func isDue(
        lastSweptAt: Date?,
        now: Date,
        interval: TimeInterval = interval
    ) -> Bool {
        guard let lastSweptAt else { return true }
        return now.timeIntervalSince(lastSweptAt) >= interval
    }

    /// A cancelled task is not a sync failure: the user left the screen or SwiftUI
    /// redrew it mid-refresh. Reporting it put "Swift.CancellationError" in front of the
    /// user on every pull-to-refresh.
    public static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }
}
