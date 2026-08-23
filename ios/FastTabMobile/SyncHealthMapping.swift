import Foundation
import CloudKit
import FastTabSync

/// Translates raw CloudKit outcomes into the shared, user-facing `SyncHealth`
/// vocabulary and plain-English sentences.
///
/// Pure and free of state so the wording can be reasoned about (and changed)
/// without a live iCloud account.
public enum SyncHealthMapping {
    /// Result of `CKContainer.accountStatus()`.
    public static func health(forAccountStatus status: CKAccountStatus) -> SyncHealth {
        switch status {
        case .available:
            return .ok
        case .noAccount:
            return .noAccount
        case .restricted:
            return .restricted
        case .couldNotDetermine:
            return .unknown
        case .temporarilyUnavailable:
            return .failing("iCloud is temporarily unavailable. FastTab will try again shortly.")
        @unknown default:
            return .unknown
        }
    }

    /// A failed fetch or send. Structural problems (signed out, restricted) are
    /// reported as such so the UI can tell the user what only they can fix.
    public static func health(forFailure error: Error) -> SyncHealth {
        if let cloudKitError = error as? CKError {
            switch cloudKitError.code {
            case .notAuthenticated:
                return .noAccount
            case .managedAccountRestricted:
                return .restricted
            default:
                break
            }
        }
        return .failing(message(forFailure: error))
    }

    /// User-presentable sentence for a failure. Never a raw CloudKit dump.
    public static func message(forFailure error: Error) -> String {
        guard let cloudKitError = error as? CKError else { return error.localizedDescription }
        switch cloudKitError.code {
        case .networkUnavailable, .networkFailure:
            return "No internet connection. Your changes will reach your Mac once you're back online."
        case .quotaExceeded:
            return "Your iCloud storage is full, so FastTab can't send changes. Free up iCloud space and try again."
        case .notAuthenticated:
            return "You're not signed in to iCloud. Sign in to sync with your Mac."
        case .managedAccountRestricted:
            return "A device restriction is blocking iCloud access for FastTab."
        case .requestRateLimited, .zoneBusy, .serviceUnavailable:
            return "iCloud is busy right now. FastTab will retry automatically."
        case .accountTemporarilyUnavailable:
            return "iCloud is temporarily unavailable. FastTab will retry automatically."
        case .zoneNotFound, .userDeletedZone:
            return "FastTab is setting up its iCloud storage again. Your changes will be sent once it's ready."
        default:
            return error.localizedDescription
        }
    }

    /// Whether a failed upload is worth re-queueing.
    ///
    /// Transient conditions (offline, busy, signed out, full) resolve on their
    /// own, so the command stays in the outbox and is retried. A rejection that
    /// will never succeed must instead be dropped, otherwise the "changes
    /// waiting" count sticks at a number the user can never clear.
    public static func isWorthRetrying(_ error: Error) -> Bool {
        guard let cloudKitError = error as? CKError else { return true }
        switch cloudKitError.code {
        case .networkUnavailable,
             .networkFailure,
             .serviceUnavailable,
             .requestRateLimited,
             .zoneBusy,
             .notAuthenticated,
             .quotaExceeded,
             .accountTemporarilyUnavailable,
             .internalError,
             .serverResponseLost,
             .operationCancelled,
             .zoneNotFound,
             .userDeletedZone:
            return true
        default:
            return false
        }
    }

    /// Failures `CKSyncEngine` retries on its own schedule, with backoff. The
    /// app must not re-arm or re-send these: it would spin on a dead network.
    /// Everything else in `isWorthRetrying` is ours to re-arm.
    public static func isRetriedByEngine(_ error: Error) -> Bool {
        guard let cloudKitError = error as? CKError else { return false }
        switch cloudKitError.code {
        case .networkUnavailable,
             .networkFailure,
             .serviceUnavailable,
             .requestRateLimited,
             .zoneBusy,
             .operationCancelled,
             .notAuthenticated,
             .accountTemporarilyUnavailable:
            return true
        default:
            return false
        }
    }

    /// The record's zone is gone (deleted, or never created for a newly signed-in
    /// account). Recoverable, but only after the zone is re-created.
    public static func isMissingZone(_ error: Error) -> Bool {
        guard let cloudKitError = error as? CKError else { return false }
        switch cloudKitError.code {
        case .zoneNotFound, .userDeletedZone:
            return true
        default:
            return false
        }
    }
}
