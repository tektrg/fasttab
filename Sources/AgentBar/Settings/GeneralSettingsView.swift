import SwiftUI

/// "General" tab: how the app starts and whether it shows a menu bar icon.
struct GeneralSettingsView: View {
    @ObservedObject var settings: AgentBarSettings
    @StateObject private var launchAtLogin = LaunchAtLoginService()

    var body: some View {
        Form {
            Section("System") {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                ))
                if let errorMessage = launchAtLogin.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Toggle("Show menu bar icon", isOn: Binding(
                    get: { settings.showsMenuBarIcon },
                    set: { settings.setShowsMenuBarIcon($0) }
                ))
                Text(settings.showsMenuBarIcon
                     ? "The icon's menu opens AgentBar and these settings, or quits the app."
                     : "Without the icon, open AgentBar with its shortcut, and reach these settings with the gear at the bottom of the panel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin.refreshStatus() }
    }
}
