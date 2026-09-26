import SwiftUI

/// Onboarding's extension status line. Says *why* the extension isn't usable
/// yet — turned off in Settings, stale version, or not connected — and after
/// a while of "waiting" offers the fixes that actually unstick a connection.
struct ExtensionSetupStatusView: View {
    @ObservedObject private var permissions = AutomationPermissionStore.shared
    @State private var showsNotConnectingHint = false

    /// Long enough for a fresh install to handshake (the extension retries every 5s).
    static let notConnectingHintDelay: Duration = .seconds(15)

    private var setupState: ExtensionSetupState { permissions.extensionSetupState }

    var body: some View {
        VStack(spacing: 8) {
            statusLine
            detail
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 18)
        .task(id: setupState) {
            showsNotConnectingHint = false
            guard setupState == .waiting else { return }
            try? await Task.sleep(for: Self.notConnectingHintDelay)
            if !Task.isCancelled { showsNotConnectingHint = true }
        }
    }

    private var statusLine: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
            Text(title)
                .font(.callout)
                .foregroundStyle(setupState == .waiting ? .tertiary : .secondary)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var detail: some View {
        switch setupState {
        case .turnedOff:
            Button("Turn on the extension") {
                permissions.turnOnExtensionFeature()
            }
            .controlSize(.small)
        case .versionMismatch:
            hint("Update the extension and FastTab to their latest versions, then reload the extension.")
        case .waiting where showsNotConnectingHint:
            hint("Installed it already? Open your browser's Extensions page and reload FastTab Companion, or quit and reopen the browser.")
        case .usable, .waiting:
            EmptyView()
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var title: String {
        switch setupState {
        case .usable: return "Connected ✓"
        case .turnedOff: return "Connected, but turned off in FastTab"
        case .versionMismatch: return "Connected, but versions don't match"
        case .waiting: return "Waiting for connection…"
        }
    }

    private var iconName: String {
        switch setupState {
        case .usable: return "checkmark.circle.fill"
        case .turnedOff, .versionMismatch: return "exclamationmark.circle.fill"
        case .waiting: return "circle.dashed"
        }
    }

    private var iconColor: Color {
        switch setupState {
        case .usable: return .green
        case .turnedOff, .versionMismatch: return .orange
        case .waiting: return .secondary
        }
    }
}
