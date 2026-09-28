import Foundation
import FastTabSync

/// Pure mapping from the sync state `SyncService` publishes to the words and
/// symbols Settings and the menu bar show.
///
/// Deliberately UI-framework-free and `nonisolated static` throughout: none of
/// this needs the main actor, a live iCloud account, or a running app, so the
/// wording rules can be exercised directly in tests. Copy for the *health*
/// itself is never re-invented here — it comes from `SyncHealth.shortLabel` /
/// `SyncHealth.detail`, which both platforms share.
struct SyncStatusPresentation: Equatable {
    /// How loudly the UI should present this state.
    ///
    /// `blocked` is structural — sync cannot run until the user acts, so it
    /// earns a warning colour and a call to action. `attention` is a transient
    /// failure that clears itself on the next successful round trip, so it stays
    /// quiet: a routine offline blip must not look like a broken app.
    enum Severity: Equatable {
        /// Nothing to say yet (pre-flight account check).
        case neutral
        /// Working.
        case healthy
        case attention
        case blocked
    }

    let symbolName: String
    let severity: Severity
    let title: String
    let detail: String?
    /// True when the user has something to fix in System Settings.
    let showsICloudSettingsAction: Bool

    // MARK: - Status

    nonisolated static func status(
        health: SyncHealth,
        lastSuccessfulSyncAt: Date?,
        now: Date = Date()
    ) -> SyncStatusPresentation {
        let lastSyncedPhrase = lastSuccessfulSyncAt.map { "Last synced \(relativeTimeLabel(from: $0, to: now))" }

        switch health {
        case .unknown:
            return SyncStatusPresentation(
                symbolName: "icloud",
                severity: .neutral,
                title: health.shortLabel,
                detail: lastSyncedPhrase,
                showsICloudSettingsAction: false
            )

        case .ok:
            return SyncStatusPresentation(
                symbolName: "checkmark.icloud.fill",
                severity: .healthy,
                title: health.shortLabel,
                detail: lastSyncedPhrase,
                showsICloudSettingsAction: false
            )

        case .noAccount:
            return SyncStatusPresentation(
                symbolName: "exclamationmark.icloud.fill",
                severity: .blocked,
                title: health.shortLabel,
                detail: health.detail,
                showsICloudSettingsAction: true
            )

        case .restricted:
            return SyncStatusPresentation(
                symbolName: "lock.icloud.fill",
                severity: .blocked,
                title: health.shortLabel,
                detail: health.detail,
                showsICloudSettingsAction: true
            )

        case .failing:
            // Keep the last-success reassurance attached: "couldn't reach
            // iCloud, last synced 4m ago" is a blip, and reads like one.
            let parts = [health.detail, lastSyncedPhrase].compactMap { $0 }
            return SyncStatusPresentation(
                symbolName: "arrow.triangle.2.circlepath.icloud",
                severity: .attention,
                title: health.shortLabel,
                detail: parts.isEmpty ? nil : parts.joined(separator: " · "),
                showsICloudSettingsAction: false
            )
        }
    }

    // MARK: - Menu Bar

    /// One-line summary for the menu-bar menu. Falls back to the shared
    /// `shortLabel` for every non-healthy state so the menu and Settings can
    /// never disagree about what is wrong.
    nonisolated static func menuStatusLine(
        health: SyncHealth,
        lastSuccessfulSyncAt: Date?,
        now: Date = Date()
    ) -> String {
        guard health == .ok, let lastSuccessfulSyncAt else { return health.shortLabel }
        return "\(health.shortLabel) \(relativeTimeLabel(from: lastSuccessfulSyncAt, to: now))"
    }

    // MARK: - Counts

    nonisolated static func pendingChangesPhrase(count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1
            ? "1 change waiting to upload"
            : "\(count) changes waiting to upload"
    }

    // MARK: - Paired Phones

    /// Settings > Sync row for one paired phone, e.g. "iPhone · last seen 2m ago".
    nonisolated static func pairedPhoneLine(_ phone: SyncedDevice, now: Date = Date()) -> String {
        "\(phone.name) · last seen \(relativeTimeLabel(from: phone.lastSeenAt, to: now))"
    }

    nonisolated static let noPairedPhoneLine = "No iPhone connected yet"

    // MARK: - Relative Time

    /// Compact, glanceable age. Coarser than `RelativeDateTimeFormatter` on
    /// purpose: "2m ago" is easier to scan in a settings row than "2 minutes
    /// ago", and anything older than a week is a date, not an interval.
    nonisolated static func relativeTimeLabel(from: Date, to: Date = Date()) -> String {
        let elapsedSeconds = to.timeIntervalSince(from)

        // Clock skew, or a sync that landed a heartbeat ago.
        guard elapsedSeconds >= 45 else { return "just now" }

        let minutes = Int(elapsedSeconds / 60)
        if minutes < 60 { return "\(max(minutes, 1))m ago" }

        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }

        let days = hours / 24
        if days < 7 { return "\(days)d ago" }

        return "on \(from.formatted(date: .abbreviated, time: .shortened))"
    }
}
