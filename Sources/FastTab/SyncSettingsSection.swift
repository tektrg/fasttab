import SwiftUI
import AppKit
import Combine
import FastTabSync

/// The "Sync" section of Settings — the app's only user-facing answer to "is my
/// iCloud sync actually working?".
///
/// Lives in its own file rather than inside `SettingsView` for two reasons: it
/// owns state (a ticking clock, an in-flight manual sync) that the rest of
/// Settings does not care about, and `SettingsView`'s `Form` is already long.
struct SyncSettingsSection: View {
    @ObservedObject private var syncService = SyncService.shared
    @ObservedObject private var pairedPhoneStore = PairedPhoneStore.shared

    /// Re-read every 30s so "Last synced 2m ago" does not go stale while the
    /// window sits open. Only ticks while this section is on screen.
    @State private var now = Date()
    @State private var isManualSyncInFlight = false

    /// Held in `@State` so exactly one timer exists per on-screen instance and
    /// it is torn down with the view — a `static` publisher would keep ticking
    /// for the app's whole life after Settings closed.
    @State private var clockTick = Timer.publish(every: 30, tolerance: 5, on: .main, in: .common).autoconnect()

    /// Upper bound on how long "Syncing…" can linger if CloudKit never answers.
    /// The spinner otherwise clears the moment real state changes.
    private static let manualSyncTimeout: Duration = .seconds(8)

    var body: some View {
        Section("Sync") {
            statusRow

            if status.showsICloudSettingsAction {
                Button("Open iCloud Settings") {
                    openICloudSystemSettings()
                }
                .controlSize(.small)
            }

            if let pendingChangesPhrase = SyncStatusPresentation.pendingChangesPhrase(count: syncService.pendingChangeCount) {
                detailLine(pendingChangesPhrase, symbolName: "arrow.up.circle", tint: .secondary)
            }

            pairedPhoneRows

            Text("FastTab syncs your open tabs, bookmarks, and history through your own private iCloud account. Nothing passes through anyone else's server.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onReceive(clockTick) { tick in
            now = tick
        }
        .onChange(of: syncService.lastSuccessfulSyncAt) { _, _ in
            now = Date()
            isManualSyncInFlight = false
        }
        .onChange(of: syncService.syncHealth) { _, _ in
            isManualSyncInFlight = false
        }
    }

    // MARK: - Rows

    private var statusRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: status.symbolName)
                .foregroundStyle(tint(for: status.severity))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(status.title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(status.severity == .blocked ? Color.orange : Color.primary)

                if let detail = status.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            Button(isManualSyncInFlight ? "Syncing…" : "Sync Now") {
                startManualSync()
            }
            .controlSize(.small)
            .disabled(isManualSyncInFlight || status.severity == .blocked)
            .help(status.severity == .blocked
                  ? "Sign in to iCloud first."
                  : "Upload anything waiting, then check for changes from your other devices.")
        }
    }

    /// "iPhone connected" — one line per phone that checked in within the
    /// pairing window (`SyncedDevicePairing.phonePairingWindow`).
    @ViewBuilder
    private var pairedPhoneRows: some View {
        let phones = SyncedDevicePairing.pairedPhones(in: pairedPhoneStore.phones, now: now)
        if phones.isEmpty {
            detailLine(SyncStatusPresentation.noPairedPhoneLine, symbolName: "iphone.slash", tint: .secondary)
        } else {
            ForEach(phones) { phone in
                detailLine(SyncStatusPresentation.pairedPhoneLine(phone, now: now), symbolName: "iphone", tint: .green)
            }
        }
    }

    private func detailLine(_ text: String, symbolName: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbolName)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(text)
                .font(.callout)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Derived State

    private var status: SyncStatusPresentation {
        SyncStatusPresentation.status(
            health: syncService.syncHealth,
            lastSuccessfulSyncAt: syncService.lastSuccessfulSyncAt,
            now: now
        )
    }

    private func tint(for severity: SyncStatusPresentation.Severity) -> Color {
        switch severity {
        case .neutral: return .secondary
        case .healthy: return .green
        // Transient: a network blip is not a broken app, so it stays as quiet
        // as the healthy state and only the wording changes.
        case .attention: return .secondary
        case .blocked: return .orange
        }
    }

    // MARK: - Actions

    /// Pushes anything queued, then pulls. Both are `SyncService`'s own
    /// entry points — this view never talks to CloudKit directly.
    ///
    /// Never reachable while sync is blocked. A fetch with no iCloud account
    /// fails, and `SyncService` would then publish `.failing` over the
    /// `.noAccount` state — trading a specific, actionable instruction for a
    /// vague error. "Open iCloud Settings" is the only useful action there, and
    /// signing in fires `CKAccountChanged`, which corrects the status by itself.
    private func startManualSync() {
        isManualSyncInFlight = true
        syncService.sendPendingChanges()
        syncService.fetchLatestChanges()

        Task {
            try? await Task.sleep(for: Self.manualSyncTimeout)
            isManualSyncInFlight = false
        }
    }

    private func openICloudSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings") else { return }
        NSWorkspace.shared.open(url)
    }
}
