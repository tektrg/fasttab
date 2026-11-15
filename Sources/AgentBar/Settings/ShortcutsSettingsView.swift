import IndieCommandBar
import IndieEdgeReveal
import IndieEdgeRevealUI
import IndieSettings
import SwiftUI

/// "Shortcuts" tab: how AgentBar is opened (hover spot + summon shortcut, the "Trigger" section every
/// app has), Focus mode's shortcut, and the cycling rule. Changed live.
struct ShortcutsSettingsView: View {
    @ObservedObject var settings: AgentBarSettings
    let actions: AgentBarSettingsActions
    @State private var problem: String?
    @State private var focusProblem: String?

    var body: some View {
        SettingsForm {
            Section("Trigger") {
                EdgeRevealStylePicker(style: Binding(
                    get: { settings.hoverSpot },
                    set: { settings.setHoverSpot($0) }
                ))
                .disabled(!settings.showsCornerTab)
                LabeledContent("Open AgentBar") {
                    ShortcutRecorderField(
                        shortcut: settings.hotkey.viewShortcut,
                        onRecord: record,
                        onRecordingChange: { isRecording in
                            if isRecording { problem = nil }
                            actions.setHotkeyRecording(isRecording)
                        },
                        onRejected: { problem = Self.needsModifierMessage }
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
                        apply(.standard)
                    }
                }
                SettingsFootnote(Self.hoverFootnote(spot: settings.hoverSpot, cornerTabOn: settings.showsCornerTab))
            }

            Section("Focus mode") {
                HStack {
                    Text("Answer agents one by one")
                    Spacer()
                    ShortcutRecorderField(
                        shortcut: settings.focusHotkey.viewShortcut,
                        onRecord: { shortcut in
                            guard let config = AgentHotkeyConfig.recorded(shortcut) else {
                                focusProblem = Self.needsModifierMessage
                                return
                            }
                            focusProblem = actions.changeFocusHotkey(config).message
                        },
                        onRecordingChange: { isRecording in
                            if isRecording { focusProblem = nil }
                            actions.setHotkeyRecording(isRecording)
                        },
                        onRejected: { focusProblem = Self.needsModifierMessage }
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
    }

    static let needsModifierMessage = "Hold at least one of ⌘ ⌥ ⌃ ⇧ while pressing the key."

    /// The note under the Trigger rows; says what the hover does and what it needs.
    static func hoverFootnote(spot: EdgeRevealStyle, cornerTabOn: Bool) -> String {
        let shortcut = "The shortcut opens AgentBar anywhere."
        guard cornerTabOn else { return "\(shortcut) Hover to open needs the corner tab (General › Alerts) turned on." }
        guard spot != .off else { return "\(shortcut) The corner tab still slides in at the bottom-right when an agent needs you." }
        return "\(shortcut) Rest the pointer on the \(spot.displayName.lowercased()) to open AgentBar there; the corner tab slides in from that spot when an agent needs you."
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

    private func record(_ shortcut: ViewShortcut) {
        guard let config = AgentHotkeyConfig.recorded(shortcut) else {
            problem = Self.needsModifierMessage
            return
        }
        apply(config)
    }

    private func apply(_ requested: AgentHotkeyConfig) {
        problem = actions.changeHotkey(requested).message
    }
}
