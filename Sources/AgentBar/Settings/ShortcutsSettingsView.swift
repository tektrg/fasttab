import SwiftUI

/// "Shortcuts" tab: the summon shortcut, changed live.
struct ShortcutsSettingsView: View {
    @ObservedObject var settings: AgentBarSettings
    let actions: AgentBarSettingsActions
    @State private var problem: String?
    @State private var focusProblem: String?

    var body: some View {
        Form {
            Section("Summon shortcut") {
                HStack {
                    Text("Open AgentBar")
                    Spacer()
                    ShortcutRecorderField(
                        displayString: settings.hotkey.displayName,
                        onRecord: record,
                        onKeyWithoutModifier: {
                            problem = "Hold at least one of ⌘ ⌥ ⌃ ⇧ while pressing the key."
                        },
                        onRecordingChange: { isRecording in
                            if isRecording { problem = nil }
                            actions.setHotkeyRecording(isRecording)
                        }
                    )
                }
                if let problem {
                    Text(problem)
                        .font(.avenir(size: 10))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if settings.hotkey != .standard {
                    Button("Reset to \(AgentHotkeyConfig.standard.displayName)") {
                        problem = nil
                        record(.standard)
                    }
                }
            }

            Section("Focus mode") {
                HStack {
                    Text("Answer agents one by one")
                    Spacer()
                    ShortcutRecorderField(
                        displayString: settings.focusHotkey.displayName,
                        onRecord: { focusProblem = actions.changeFocusHotkey($0).message },
                        onKeyWithoutModifier: {
                            focusProblem = "Hold at least one of ⌘ ⌥ ⌃ ⇧ while pressing the key."
                        },
                        onRecordingChange: { isRecording in
                            if isRecording { focusProblem = nil }
                            actions.setHotkeyRecording(isRecording)
                        }
                    )
                }
                if let focusProblem {
                    Text(focusProblem)
                        .font(.avenir(size: 10))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if settings.focusHotkey != FocusHotkey.standard {
                    Button("Reset to \(FocusHotkey.standard.displayName)") {
                        focusProblem = actions.changeFocusHotkey(FocusHotkey.standard).message
                    }
                }
                Text("Opens a full-screen card for each agent that needs you. ⌘F does the same while the panel is open.")
                    .font(.avenir(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Switching") {
                Text("Hold the modifier keys and tap the key again to move down the list; let go to switch to the selected agent.")
                    .font(.avenir(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                backwardCyclingRow
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var backwardCyclingRow: some View {
        if let backward = settings.hotkey.backwardDisplayName {
            HStack {
                Text("Cycle backward")
                Spacer()
                Text(backward)
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text("Adding ⇧ to the shortcut moves up the list instead.")
                .font(.avenir(size: 10))
                .foregroundStyle(.secondary)
        } else {
            Text("Backward cycling is unavailable: this shortcut already uses ⇧. Choose one without ⇧ to get it.")
                .font(.avenir(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func record(_ requested: AgentHotkeyConfig) {
        problem = actions.changeHotkey(requested).message
    }
}
