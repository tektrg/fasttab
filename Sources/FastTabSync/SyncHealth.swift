import Foundation

/// Cross-platform description of whether sync can work at all right now.
///
/// Both `SyncService` (macOS) and `SyncConsumer` (iOS) publish one of these so
/// their UI layers can render a single, honest status instead of silently
/// no-oping. `unknown` is the pre-flight value before the first account check.
public enum SyncHealth: Equatable, Sendable {
    case unknown
    case ok
    /// Signed out of iCloud, or iCloud Drive disabled for this container.
    case noAccount
    /// Managed/parental restriction prevents CloudKit access.
    case restricted
    /// Last CloudKit operation failed. Carries a user-presentable message.
    case failing(String)

    /// True when sync is structurally unable to run, as opposed to having hit
    /// a transient error that may recover on its own.
    public var isBlocked: Bool {
        switch self {
        case .noAccount, .restricted: return true
        case .unknown, .ok, .failing: return false
        }
    }

    /// Short, user-facing label. Never contains raw CloudKit error codes.
    public var shortLabel: String {
        switch self {
        case .unknown: return "Checking iCloud…"
        case .ok: return "Synced"
        case .noAccount: return "Sign in to iCloud to sync"
        case .restricted: return "iCloud is restricted on this device"
        case .failing: return "Sync problem"
        }
    }

    /// Longer explanation, including the underlying message when there is one.
    public var detail: String? {
        switch self {
        case .unknown, .ok: return nil
        case .noAccount: return "FastTab syncs your tabs through your private iCloud account. Sign in to iCloud in Settings, then reopen FastTab."
        case .restricted: return "A device restriction is blocking iCloud access for FastTab."
        case .failing(let message): return message
        }
    }
}

/// How far an outbound command has physically travelled.
///
/// Distinct from `SyncCommand.status`, which describes what the *receiving*
/// device decided to do. A command can be `queuedLocally` for a long time
/// (offline phone) while its `status` is still `.pending` — the UI must be able
/// to tell those apart, because only one of them is the user's problem.
public enum SyncCommandDelivery: String, Codable, Sendable, Hashable {
    /// Written to the local durable outbox; not yet accepted by CloudKit.
    case queuedLocally
    /// CloudKit confirmed the write. Waiting for the target device to act.
    case uploaded
    /// The target device wrote back a terminal status.
    case acknowledged
}
