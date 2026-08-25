import Foundation
import CloudKit
import FastTabSync

/// Translates CloudKit's failure vocabulary into the single `SyncHealth` value
/// the app publishes to its UI.
///
/// Kept as pure functions so the mapping — the part that is easy to get subtly
/// wrong and impossible to observe in production — is unit-testable without a
/// live CloudKit container.
enum SyncHealthDiagnostics {
    /// Maps an iCloud account status onto publishable health.
    ///
    /// `couldNotDetermine` and `temporarilyUnavailable` both map to `.unknown`
    /// rather than `.failing`: neither is user-actionable and neither proves
    /// anything is broken. `couldNotDetermine` routinely appears at launch
    /// before the account daemon answers, and Apple's guidance for
    /// `temporarilyUnavailable` is explicitly to keep cached data and wait for
    /// a `CKAccountChanged` notification — which we observe. Showing "Sync
    /// problem" for either would be a lie the user cannot act on.
    static func health(forAccountStatus status: CKAccountStatus) -> SyncHealth {
        switch status {
        case .available: return .ok
        case .noAccount: return .noAccount
        case .restricted: return .restricted
        case .couldNotDetermine, .temporarilyUnavailable: return .unknown
        @unknown default: return .unknown
        }
    }

    /// A message safe to render in the UI. Never contains a CloudKit error code.
    static func userPresentableMessage(for error: Error) -> String {
        guard let cloudKitError = error as? CKError else {
            return error.localizedDescription
        }

        switch cloudKitError.code {
        case .networkUnavailable, .networkFailure, .serviceUnavailable:
            return "No connection to iCloud right now. FastTab will retry automatically."
        case .quotaExceeded:
            return "Your iCloud storage is full. Free up space in System Settings › Apple Account › iCloud, then FastTab will resume syncing."
        case .notAuthenticated:
            return "You're not signed in to iCloud. Sign in to keep your tabs in sync."
        case .requestRateLimited, .zoneBusy:
            return "iCloud asked FastTab to slow down. Syncing will resume shortly."
        case .permissionFailure, .managedAccountRestricted:
            return "iCloud access is restricted for this account."
        case .changeTokenExpired:
            return "iCloud asked FastTab to resync from scratch. This finishes on its own."
        case .partialFailure:
            // A partial failure's own description is the useless "Some items
            // failed" string; the actionable cause (almost always quota or
            // auth) is in the per-item errors, so surface the first of those.
            guard let firstUnderlyingError = firstPartialError(in: cloudKitError) else {
                return "Some items couldn't be synced. FastTab will retry automatically."
            }
            return userPresentableMessage(for: firstUnderlyingError)
        default:
            return cloudKitError.localizedDescription
        }
    }

    /// True when a failure means "this zone doesn't exist yet", which is the
    /// normal state before the first zone save lands and is not worth alarming
    /// the user about.
    static func isExpectedMissingZone(_ error: Error) -> Bool {
        guard let cloudKitError = error as? CKError else { return false }
        switch cloudKitError.code {
        case .zoneNotFound, .userDeletedZone, .unknownItem: return true
        case .partialFailure:
            guard let firstUnderlyingError = firstPartialError(in: cloudKitError) else { return false }
            return isExpectedMissingZone(firstUnderlyingError)
        default: return false
        }
    }

    private static func firstPartialError(in cloudKitError: CKError) -> Error? {
        guard let partialErrors = cloudKitError.partialErrorsByItemID else { return nil }
        // Sorted by key description purely for determinism: without it the
        // message the user sees would vary run to run for the same failure.
        return partialErrors
            .sorted { String(describing: $0.key) < String(describing: $1.key) }
            .first?
            .value
    }
}
