import SwiftUI
import FastTabSync

/// The one place every screen reports whether syncing is working.
///
/// Three separate questions, answered top to bottom so the most actionable one
/// is never buried:
///
/// 1. Can sync run at all? (`SyncHealth` — a signed-out phone gets a card, not
///    a caption, because nothing else in the app will ever work until it is fixed)
/// 2. Is the Mac's data current? (device heartbeat)
/// 3. Is anything still waiting to leave this phone? (`pendingCommandCount`)
public struct DataFreshnessBanner: View {
    public let device: SyncedDevice?
    public let lastSyncedAt: Date?

    @ObservedObject private var syncConsumer = SyncConsumer.shared

    public init(device: SyncedDevice?, lastSyncedAt: Date? = nil) {
        self.device = device
        self.lastSyncedAt = lastSyncedAt
    }

    private var healthBadge: SyncStatusCopy.HealthBadge? {
        SyncStatusCopy.healthBadge(for: syncConsumer.syncHealth)
    }

    private var freshness: SyncStatusCopy.MacFreshness {
        SyncStatusCopy.macFreshness(device: device)
    }

    /// Prefer the last proven round trip. `lastSyncedAt` (the cache's own write
    /// time) is the fallback for a cache restored from a previous launch.
    private var lastSyncPhrase: String? {
        guard let moment = syncConsumer.lastSuccessfulSyncAt ?? lastSyncedAt else { return nil }
        return "Synced \(SyncStatusCopy.relativeTimeLabel(from: moment))"
    }

    private var pendingPhrase: String? {
        SyncStatusCopy.pendingChangesPhrase(count: syncConsumer.pendingCommandCount)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            if let healthBadge, healthBadge.severity == .blocked {
                blockedCard(healthBadge)
            } else {
                macLivenessRow
                if let healthBadge {
                    quietProblemRow(healthBadge)
                }
            }

            if let pendingPhrase {
                pendingChangesRow(pendingPhrase)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.sm)
        .background(DS.Palette.surface)
        .animation(.easeInOut(duration: 0.2), value: healthBadge)
        .animation(.easeInOut(duration: 0.2), value: pendingPhrase)
    }

    // MARK: - Rows

    /// Structurally broken: the user has to do something outside the app, so
    /// this gets a tinted card and the full explanation rather than a caption.
    @ViewBuilder
    private func blockedCard(_ badge: SyncStatusCopy.HealthBadge) -> some View {
        HStack(alignment: .top, spacing: DS.Space.md) {
            Image(systemName: badge.symbolName)
                .font(.system(size: DS.IconSize.row))
                .foregroundStyle(DS.Tint.warning)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(badge.title)
                    .font(DS.Font.cardTitle)
                    .foregroundStyle(.primary)

                if let detail = badge.detail {
                    Text(detail)
                        .font(DS.Font.meta)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(DS.Space.md)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                .fill(DS.Tint.warning.opacity(DS.tintFillOpacity))
        )
    }

    private var macLivenessRow: some View {
        HStack(spacing: DS.Space.sm) {
            Circle()
                .fill(freshness.tint)
                .frame(width: 8, height: 8)

            Text(freshness.text)
                .font(DS.Font.meta)
                .foregroundStyle(.secondary)

            Spacer(minLength: DS.Space.sm)

            if syncConsumer.isSyncing {
                HStack(spacing: 5) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Syncing…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .transition(.opacity)
            } else if let lastSyncPhrase {
                Text(lastSyncPhrase)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
        }
    }

    /// A transient failure. Visible, but quiet: the next successful round trip
    /// clears it without the user lifting a finger.
    @ViewBuilder
    private func quietProblemRow(_ badge: SyncStatusCopy.HealthBadge) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: badge.symbolName)
                .font(.caption2)
                .foregroundStyle(DS.Tint.warning)

            Text(badge.detail ?? badge.title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func pendingChangesRow(_ phrase: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.up.circle")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text(phrase)
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
    }
}
