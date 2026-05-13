import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var launchAtLogin = LaunchAtLoginService.shared
    @ObservedObject private var shortcutStore = ShortcutStore.shared

    @AppStorage("FastTab.safari.includeFDAData") private var includeSafariFDAData: Bool = false

    @State private var fdaInitiallyGranted: Bool = false
    @State private var fdaGrantedNow: Bool = false

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                ))

                if let errorMessage = launchAtLogin.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Shortcut") {
                HStack {
                    Text("Global shortcut")
                    Spacer()
                    ShortcutRecorderView(store: shortcutStore)
                }

                if let issue = appState.globalShortcutRegistrationIssue {
                    Text(issue)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

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
                                restartApp()
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
        .formStyle(.grouped)
        .frame(width: 480)
        .frame(minHeight: 360)
        .onAppear {
            fdaInitiallyGranted = appState.browserService.canReadSafariProtectedData()
            fdaGrantedNow = fdaInitiallyGranted
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            fdaGrantedNow = appState.browserService.canReadSafariProtectedData()
        }
    }

    private func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    private func restartApp() {
        let bundleURL = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
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
