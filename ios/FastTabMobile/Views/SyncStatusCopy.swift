import SwiftUI
import FastTabSync

/// Pure mapping from the sync state `SyncConsumer` publishes to the words,
/// symbols and loudness the iOS UI shows.
///
/// Deliberately mirrors macOS `SyncStatusPresentation` — same severity
/// vocabulary, same relative-time wording — so the two apps never describe one
/// sync state in two different ways. Copy for the *health* itself is never
/// re-invented here: it comes from `SyncHealth.shortLabel` / `SyncHealth.detail`,
/// which both platforms share.
enum SyncStatusCopy {

    /// How loudly a state should be presented.
    ///
    /// `blocked` is structural — sync cannot run at all until the user acts, so
    /// it earns prominence. `attention` is a transient failure that clears
    /// itself on the next successful round trip, so it stays quiet: a routine
    /// offline blip must not look like a broken app.
    enum Severity {
        case normal
        case attention
        case blocked
    }

    /// A sync-health line worth showing. `nil` means "nothing to say" — the
    /// banner then just reports how fresh the Mac's data is.
    struct HealthBadge: Equatable {
        let symbolName: String
        let severity: Severity
        let title: String
        let detail: String?
    }

    static func healthBadge(for health: SyncHealth) -> HealthBadge? {
        switch health {
        case .ok, .unknown:
            // Healthy, or too early to know. Either way there is no problem to
            // report, and "Checking iCloud…" on every launch is just noise.
            return nil
        case .noAccount:
            return HealthBadge(
                symbolName: "exclamationmark.icloud.fill",
                severity: .blocked,
                title: health.shortLabel,
                detail: health.detail
            )
        case .restricted:
            return HealthBadge(
                symbolName: "lock.icloud.fill",
                severity: .blocked,
                title: health.shortLabel,
                detail: health.detail
            )
        case .failing:
            return HealthBadge(
                symbolName: "exclamationmark.triangle.fill",
                severity: .attention,
                title: health.shortLabel,
                detail: health.detail
            )
        }
    }

    // MARK: - Mac liveness

    /// How recently the Mac last proved it was awake.
    struct MacFreshness: Equatable {
        let text: String
        let tint: Color
        /// True when the Mac's data can no longer be trusted as current.
        let isStale: Bool
        /// True when there is no Mac, or it has been silent for a day or more:
        /// no longer "probably asleep", so worth a warning outside More.
        var isOffline: Bool = false
    }

    /// The Mac republishes its device record every 3 minutes while it is awake
    /// (`SyncService.deviceHeartbeatInterval`). Every threshold below is derived
    /// from that one number, because a 3-minute signal cannot support finer
    /// claims than "we heard from it recently / we haven't for a while".
    private static let heartbeatInterval: TimeInterval = 3 * 60
    /// One heartbeat plus slack for upload and fetch latency.
    private static let liveWindow: TimeInterval = heartbeatInterval + 60
    /// Several missed beats. Below this it is far more likely a network blip
    /// than a sleeping Mac, so we report the age and claim nothing else.
    private static let quietWindow: TimeInterval = heartbeatInterval * 5
    private static let oneDay: TimeInterval = 24 * 60 * 60

    static func macFreshness(device: SyncedDevice?, now: Date = Date()) -> MacFreshness {
        guard let device else {
            return MacFreshness(text: "No Mac connected", tint: .secondary, isStale: true, isOffline: true)
        }

        let elapsed = now.timeIntervalSince(device.lastSeenAt)
        let age = relativeTimeLabel(from: device.lastSeenAt, to: now)

        if elapsed < liveWindow {
            return MacFreshness(text: "Active now", tint: DS.Tint.success, isStale: false)
        }
        if elapsed < quietWindow {
            return MacFreshness(text: "Last seen \(age)", tint: .secondary, isStale: false)
        }
        if elapsed < oneDay {
            // "May be" is not hedging for its own sake: asleep, quit and offline
            // are indistinguishable from here, and only one of them is worth
            // the user's attention.
            return MacFreshness(text: "Mac may be asleep — last seen \(age)", tint: DS.Tint.warning, isStale: true)
        }
        return MacFreshness(text: "Mac offline — last seen \(age)", tint: DS.Tint.destructive, isStale: true, isOffline: true)
    }

    // MARK: - Counts

    static func pendingChangesPhrase(count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1
            ? "1 change waiting to reach your Mac"
            : "\(count) changes waiting to reach your Mac"
    }

    // MARK: - Relative time

    /// Compact, glanceable age. Coarser than `RelativeDateTimeFormatter` on
    /// purpose: "2m ago" scans faster than "2 minutes ago", and anything older
    /// than a week is a date, not an interval. Same wording as macOS.
    static func relativeTimeLabel(from: Date, to: Date = Date()) -> String {
        let elapsedSeconds = to.timeIntervalSince(from)

        // Clock skew, or something that landed moments ago.
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
