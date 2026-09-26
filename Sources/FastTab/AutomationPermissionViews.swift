import SwiftUI
import AppKit

/// One-row command-bar banner shown when an enabled source has been denied
/// Automation access — otherwise that source just silently contributes no tabs.
/// Lives inside the results section so it spends the existing row budget
/// instead of growing the fixed-size window.
struct AutomationDeniedBanner: View {
    /// The bar is a persistent, non-activating panel, so `onAppear` fires once;
    /// re-probe each time it's shown (e.g. after the user fixed it in Settings).
    let isCommandBarVisible: Bool
    @ObservedObject private var permissions = AutomationPermissionStore.shared

    var body: some View {
        let denied = permissions.deniedSources
        // VStack, not Group: an empty Group has no child to attach onAppear to.
        VStack(spacing: 0) {
            if !denied.isEmpty {
                PermissionBanner(
                    icon: "lock.trianglebadge.exclamationmark",
                    tint: .orange,
                    message: Self.message(for: denied),
                    actionTitle: "Fix"
                ) {
                    permissions.openAutomationSettings()
                }
                .padding(.horizontal, 8)
                .padding(.top, 6)
            }
        }
        .onAppear { permissions.recheck() }
        .onChange(of: isCommandBarVisible) { _, visible in
            if visible { permissions.recheck() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.recheck()
        }
    }

    nonisolated static func message(for denied: [SearchSource]) -> String {
        let names = denied.map(\.displayName).joinedAsNaturalList(conjunction: "and")
        return "\(names) can't be read — allow FastTab in Automation settings."
    }
}

/// Settings list: Automation status for each enabled source, with Recheck,
/// Allow (prompts) and Fix (opens System Settings) actions.
struct AutomationPermissionSection: View {
    @ObservedObject private var permissions = AutomationPermissionStore.shared
    @ObservedObject private var sourceSelection = SourceSelectionStore.shared

    var body: some View {
        Section {
            ForEach(permissions.trackedSources) { source in
                row(for: source, status: permissions.statuses[source])
            }
        } header: {
            HStack {
                Text("Automation Access")
                Spacer()
                Button("Recheck") { permissions.recheck() }
                    .controlSize(.small)
            }
        } footer: {
            Text("FastTab reads tabs and windows by asking each app via Automation. A denied app shows no results until it's allowed in System Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { permissions.recheck() }
        .onChange(of: sourceSelection.enabled) { _, _ in permissions.recheck() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.recheck()
        }
    }

    @ViewBuilder
    private func row(for source: SearchSource, status: AutomationPermissionStatus?) -> some View {
        HStack(spacing: 8) {
            Text(source.displayName)
            Spacer()
            statusLabel(status)
            switch status {
            case .denied:
                Button("Fix") { permissions.openAutomationSettings() }
                    .controlSize(.small)
                    .accessibilityLabel("Fix \(source.displayName) access")
            case .notYetAsked, .appNotRunning:
                Button("Allow") { Task { await permissions.requestAccess(for: source) } }
                    .controlSize(.small)
                    .accessibilityLabel("Allow \(source.displayName)")
                    .disabled(permissions.requestInFlight != nil)
            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func statusLabel(_ status: AutomationPermissionStatus?) -> some View {
        switch status {
        case .granted:
            Label(AutomationPermissionStatus.granted.displayText, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
        case .denied:
            Label(AutomationPermissionStatus.denied.displayText, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.orange)
                .font(.callout)
        case .some(let other):
            Text(other.displayText)
                .foregroundStyle(.secondary)
                .font(.callout)
        case .none:
            ProgressView().controlSize(.small)
                .accessibilityLabel("Checking access")
        }
    }
}
