import SwiftUI

/// "General" tab: how the app starts, whether it shows a menu bar icon, and
/// whether it peeks at the corner when an agent needs the user.
struct GeneralSettingsView: View {
    @ObservedObject var settings: AgentBarSettings
    @StateObject private var launchAtLogin = LaunchAtLoginService()
    private let previewPlayer: SoundPlayer = SystemSoundPlayer()

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

            Section("Alerts") {
                Toggle("Corner tab (bottom-right)", isOn: Binding(
                    get: { settings.showsCornerTab },
                    set: { settings.setShowsCornerTab($0) }
                ))
                Text("A small tab slides in at the bottom-right for a few seconds when an agent needs you, and whenever you rest the pointer in the bottom-right corner of the screen. While an agent is waiting for your answer or approval it stays until you deal with it. Click it to open AgentBar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Play sounds", isOn: Binding(
                    get: { settings.sounds.playsSounds },
                    set: { isOn in settings.updateSounds { $0.playsSounds = isOn } }
                ))
                soundPicker("Needs you", cue: .needsAnswer)
                soundPicker("Agent done", cue: .agentDone)
                Text("Needs you plays when an agent is waiting for your answer or permission. Agent done plays when an agent has simply finished. Picking a sound previews it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin.refreshStatus() }
    }

    private func soundPicker(_ title: String, cue: SoundCue) -> some View {
        Picker(title, selection: Binding(
            get: { settings.sounds.choice(for: cue) },
            set: { choice in
                settings.updateSounds { sounds in
                    switch cue {
                    case .needsAnswer: sounds.needsAnswer = choice
                    case .agentDone: sounds.agentDone = choice
                    }
                }
                previewPlayer.play(choice)
            }
        )) {
            ForEach(SoundChoice.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .disabled(!settings.sounds.playsSounds)
    }
}
