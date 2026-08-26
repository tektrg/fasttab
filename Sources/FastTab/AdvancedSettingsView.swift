import SwiftUI
import AppKit

/// "Advanced" tab of Settings: opt-in beta features and Safari's extra
/// permission (Full Disk Access) for bookmarks/history.
struct AdvancedSettingsView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var sourceSelection = SourceSelectionStore.shared
    @StateObject private var extensionBridge = ExtensionBridge.shared

    @AppStorage(ExtensionBetaPreference.defaultsKey) private var extensionBetaEnabled: Bool = false
    @AppStorage("FastTab.safari.includeFDAData") private var includeSafariFDAData: Bool = false

    @State private var fdaInitiallyGranted: Bool = false
    @State private var fdaGrantedNow: Bool = false

    var body: some View {
        Form {
            Section("Beta") {
                Toggle("Browser extension (beta)", isOn: $extensionBetaEnabled)

                if extensionBetaEnabled {
                    Text("Opt-in experiment: reads and switches Chrome/Edge/Brave tabs through a companion extension — instant results, no macOS Automation prompt. Everything still works with it off.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(ChromiumBrowserSpec.all, id: \.source) { spec in
                        extensionStatusRow(for: spec)
                    }

                    if let storeURL = URL(string: "https://chromewebstore.google.com/detail/\(FastTabExtensionIdentity.id)") {
                        Link("Install the extension", destination: storeURL)
                            .font(.callout)
                    }
                }
            }

            if sourceSelection.isEnabled(.safari) {
                Section("Safari") {
                    Toggle("Include Safari bookmarks and history", isOn: $includeSafariFDAData)

                    if includeSafariFDAData {
                        Text("Requires Full Disk Access. Without it, Safari tabs still work but bookmarks, history, and favicons will not appear.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(alignment: .center, spacing: 14) {
                            AppIconDragView(size: 64, onClick: openFullDiskAccessSettings)
                                .frame(width: 64, height: 64)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Drag this icon into Full Disk Access")
                                    .font(.callout.weight(.medium))
                                Text("Or click the icon to open System Settings.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 4)

                        if fdaGrantedNow && !fdaInitiallyGranted {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text("Full Disk Access granted — restart FastTab to apply.")
                                    .font(.callout)
                                Spacer()
                                Button("Restart") {
                                    restartFastTab()
                                }
                                .controlSize(.small)
                            }
                        }
                    }

                    HStack(spacing: 8) {
                        Text("Safari automation:")
                            .foregroundStyle(.secondary)
                        Text(safariAutomationStatusText)
                            .font(.callout.weight(.medium))
                        Spacer()
                        Button("Recheck") {
                            appState.browserService.recheckSafariAutomation()
                        }
                        .controlSize(.small)
                    }
                    .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            fdaInitiallyGranted = appState.browserService.canReadSafariProtectedData()
            fdaGrantedNow = fdaInitiallyGranted
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            fdaGrantedNow = appState.browserService.canReadSafariProtectedData()
        }
    }

    @ViewBuilder
    private func extensionStatusRow(for spec: ChromiumBrowserSpec) -> some View {
        let connection = extensionBridge.status.first(where: { $0.appName == spec.appName })
        let browserRunning = isAppRunning(bundleIdentifier: spec.bundleIdentifier)

        HStack {
            Text(spec.appName)
                .foregroundStyle(.primary)
            Spacer()
            if let connection, connection.versionMismatch {
                Label("Version mismatch", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            } else if let connection, connection.isConnected {
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            } else if browserRunning {
                Label("Not installed", systemImage: "circle.dashed")
                    .foregroundStyle(.orange)
                    .font(.callout)
            } else {
                Text("Not running")
                    .foregroundStyle(.tertiary)
                    .font(.callout)
            }
        }
    }

    private func isAppRunning(bundleIdentifier: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleIdentifier }
    }

    private func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    private var safariAutomationStatusText: String {
        switch appState.browserService.safariAutomationStatus {
        case .notInstalled:
            return "Safari not installed"
        case .granted:
            return "granted"
        case .denied:
            return "denied"
        case .notDetermined:
            return "not yet requested"
        }
    }
}
