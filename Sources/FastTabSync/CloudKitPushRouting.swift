import Foundation
import CloudKit

/// Decides whether an incoming remote notification is CloudKit telling us this
/// app's data changed — the one signal that makes sync event-driven instead of
/// polled.
///
/// A pure decision on purpose. `CKContainer` hard-traps in an unentitled test
/// host, so the only testable place for this logic is a function that never
/// touches one.
public enum CloudKitPushRouting {
    public enum Decision: Equatable {
        /// A CloudKit change notification for our container: pull now.
        case fetchChanges
        /// Not ours, or not CloudKit at all.
        case ignore
    }

    public static func decision(forRemoteNotification userInfo: [AnyHashable: Any]) -> Decision {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) else {
            return .ignore
        }
        return decision(containerIdentifier: notification.containerIdentifier)
    }

    /// Split out from the `CKNotification` parse so the rule itself is testable.
    public static func decision(containerIdentifier: String?) -> Decision {
        // A nil identifier means CloudKit could not say which container the push
        // was for. Fetch anyway: a redundant fetch costs one no-op round trip,
        // a skipped one costs realtime until the next poll.
        guard let containerIdentifier else { return .fetchChanges }
        return containerIdentifier == SyncConstants.containerIdentifier ? .fetchChanges : .ignore
    }
}
