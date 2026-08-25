import Foundation
import CloudKit
import FastTabSync

/// Pure rules for deciding whether an inbound `SyncCommand` is this Mac's to act on.
///
/// Shared by the two delivery paths — the fast `CKSyncEngine` change feed and the
/// slow token-independent recovery sweep — so the two can never disagree about
/// what "addressed to me and still pending" means.
enum IncomingCommandFilter {
    /// An empty target or `"*"` is a broadcast: older phone builds shipped
    /// before commands carried a concrete device ID, and both still mean "any
    /// Mac signed into this iCloud account may act on this".
    static func isAddressedToDevice(_ command: SyncCommand, deviceID: String) -> Bool {
        command.targetDeviceID == deviceID
            || command.targetDeviceID.isEmpty
            || command.targetDeviceID == "*"
    }

    /// Commands worth re-feeding through the normal delivery path after a full
    /// re-read of the commands zone.
    ///
    /// Only `.pending` records are candidates: any other status means some
    /// device already wrote back a decision, and re-delivering it would fight
    /// that decision. Expired-but-pending commands are intentionally *kept* —
    /// the delivery path turns them into an `.expired` write-back, which is how
    /// abandoned records get garbage collected off the server.
    static func redeliverableCommands(in records: [CKRecord], deviceID: String) -> [SyncCommand] {
        records
            .compactMap(SyncCommand.init(from:))
            .filter { $0.status == .pending && isAddressedToDevice($0, deviceID: deviceID) }
    }
}
