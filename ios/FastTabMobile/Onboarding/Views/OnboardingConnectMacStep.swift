import SwiftUI
import FastTabSync

/// Where Mac users download FastTab (the site's FastTab home page, which links the DMG).
enum FastTabMacApp {
    static let downloadPageURL = URL(string: "https://fasttab.theindie.app/")!
}

/// Screen 2: live check that this iPhone can see a Mac.
///
/// Reads the same facts the rest of the app does (`SyncConsumer.syncHealth`,
/// the cached device records) — no new sync calls. The Mac is a soft
/// requirement: after `MacConnectionState.searchPatience` the user may go on
/// without one.
struct OnboardingConnectMacStep: View {
    /// One-screen sheet: the button closes it and never blocks.
    let isStandalone: Bool
    let onContinue: () -> Void
    let onContinueWithoutMac: () -> Void

    @ObservedObject private var syncConsumer = SyncConsumer.shared
    @ObservedObject private var localCache = LocalCache.shared
    @State private var hasWaitedLongEnough = false
    /// Restarts the patience timer when the user taps "Check again".
    @State private var searchAttempt = 0

    private var connection: MacConnectionState {
        MacConnectionState.resolve(
            health: syncConsumer.syncHealth,
            devices: localCache.state.devices,
            tabs: localCache.state.tabs,
            hasWaitedLongEnough: hasWaitedLongEnough
        )
    }

    var body: some View {
        OnboardingStepLayout(
            systemImage: "laptopcomputer.and.iphone",
            title: "Connect your Mac",
            message: "FastTab syncs with your Mac over iCloud. Use the same Apple Account on both."
        ) {
            statusCard
                .animation(DS.Motion.quick, value: connection)
        } actions: {
            OnboardingPrimaryButton(title: isStandalone ? "Done" : "Continue", action: onContinue)
                .disabled(!isStandalone && !connection.isFound)
            if !isStandalone && offersContinueWithoutMac {
                OnboardingSecondaryButton(title: "Continue without a Mac", action: onContinueWithoutMac)
            }
        }
        .task(id: searchAttempt) {
            hasWaitedLongEnough = false
            // Not awaited: the patience clock starts now, so a slow or offline
            // round trip cannot leave the user stuck on "Looking…" past it.
            Task { await syncConsumer.refreshNow() }
            try? await Task.sleep(for: MacConnectionState.searchPatience)
            guard !Task.isCancelled else { return }
            hasWaitedLongEnough = true
        }
    }

    private var offersContinueWithoutMac: Bool {
        switch connection {
        case .signedOut, .restricted, .notFound: return true
        case .searching, .found: return false
        }
    }

    // MARK: - Status card

    @ViewBuilder
    private var statusCard: some View {
        switch connection {
        case .signedOut:
            accountProblem(health: .noAccount, symbol: "exclamationmark.icloud.fill")
        case .restricted:
            accountProblem(health: .restricted, symbol: "lock.icloud.fill")
        case .searching:
            statusRow(title: "Looking for your Mac…", detail: "Keep FastTab open on your Mac. This usually takes a few seconds.") {
                ProgressView()
            }
        case .found(let macName, let tabCount):
            let mac = localCache.state.connectedMac
            let isOffline = SyncStatusCopy.macFreshness(device: mac).isOffline
            statusRow(title: MacConnectionState.foundLabel(macName: macName, tabCount: tabCount), detail: MacConnectionState.foundDetail(mac: mac)) {
                Image(systemName: isOffline ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: DS.IconSize.inline))
                    .foregroundStyle(isOffline ? DS.Tint.warning : DS.Tint.success)
            }
        case .notFound:
            notFoundCard
        }
    }

    private func accountProblem(health: SyncHealth, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            statusRow(title: health.shortLabel, detail: health.detail) {
                Image(systemName: symbol)
                    .font(.system(size: DS.IconSize.inline))
                    .foregroundStyle(DS.Tint.warning)
            }
            Button {
                guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(settingsURL)
            } label: {
                Label("Open Settings", systemImage: "gear")
            }
            .buttonStyle(.dsTinted(DS.Tint.action))
        }
    }

    private var notFoundCard: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            statusRow(title: "No Mac found yet", detail: "Install FastTab on your Mac and sign in with the same Apple Account.") {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: DS.IconSize.inline))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: DS.Space.sm) {
                Link(destination: FastTabMacApp.downloadPageURL) {
                    Label("Get FastTab for Mac", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.dsTinted(DS.Tint.action))
                Button("Check again") { searchAttempt += 1 }
                    .buttonStyle(.dsTinted(.secondary))
            }
            Text("On your Mac, visit fasttab.theindie.app")
                .font(DS.Font.meta)
                .foregroundStyle(.secondary)
        }
    }

    private func statusRow<Icon: View>(title: String, detail: String?, @ViewBuilder icon: () -> Icon) -> some View {
        HStack(alignment: .top, spacing: DS.Space.md) {
            icon()
                .frame(width: DS.IconSize.inline + 4, height: DS.IconSize.inline + 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(DS.Font.cardTitle)
                if let detail {
                    Text(detail)
                        .font(DS.Font.meta)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
        .accessibilityElement(children: .combine)
    }
}
