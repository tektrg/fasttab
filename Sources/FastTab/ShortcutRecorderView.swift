import SwiftUI
import AppKit
import IndieCommandBar

struct ShortcutRecorderView: View {
    var displayString: String
    var onRecord: (UInt16, NSEvent.ModifierFlags, String) -> Void
    var onClear: (() -> Void)? = nil
    var showsSettingsButton: Bool = false

    @EnvironmentObject var appState: AppState
    @Environment(\.openSettings) private var openSettings
    @State private var isRecording = false
    @State private var monitor: Any?

    init(
        store: ShortcutStore,
        showsSettingsButton: Bool = false
    ) {
        self.displayString = store.displayString
        self.onRecord = { keyCode, mods, name in
            store.update(keyCode: keyCode, modifiers: mods, keyName: name)
        }
        self.onClear = nil
        self.showsSettingsButton = showsSettingsButton
    }

    init(
        displayString: String,
        onRecord: @escaping (UInt16, NSEvent.ModifierFlags, String) -> Void,
        onClear: (() -> Void)? = nil,
        showsSettingsButton: Bool = false
    ) {
        self.displayString = displayString.isEmpty ? "None" : displayString
        self.onRecord = onRecord
        self.onClear = onClear
        self.showsSettingsButton = showsSettingsButton
    }

    var body: some View {
        HStack(spacing: 8) {
            if showsSettingsButton {
                Button {
                    openSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Open Settings")
                .accessibilityLabel("Open Settings")
            }

            Button(action: toggleRecording) {
                Text(isRecording ? "Press keys…" : (displayString.isEmpty ? "None" : displayString))
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .foregroundStyle(isRecording ? Color.accentColor : (displayString == "None" ? Color.secondary : Color.primary))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        Capsule(style: .continuous)
                            .fill(.ultraThinMaterial)
                            .overlay(
                                Capsule(style: .continuous)
                                    .strokeBorder(
                                        isRecording ? Color.accentColor.opacity(0.65) : Color.white.opacity(0.16),
                                        lineWidth: 1
                                    )
                            )
                    )
            }
            .buttonStyle(.plain)

            if let onClear, displayString != "None", !isRecording {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear shortcut")
            }

            if isRecording {
                Text("Esc to cancel")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isRecording)
        // Only a recorder that is recording owns the app-wide flag; an idle
        // one leaving (e.g. the onboarding step advancing) must not reset it.
        .onDisappear { if isRecording { stopRecording() } }
    }

    private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        isRecording = true
        appState.isRecordingShortcut = true
        // A local monitor sees every keyDown before the window does, so Tab combos (⌃Tab,
        // ⌃⇧Tab) reach it instead of moving keyboard focus.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch Self.outcome(keyCode: event.keyCode, modifiers: event.modifierFlags, characters: event.charactersIgnoringModifiers) {
            case .cancel:
                stopRecording()
            case .ignore:
                break
            case .record(let keyCode, let mods, let name):
                onRecord(keyCode, mods, name)
                stopRecording()
            }
            return nil
        }
    }

    enum RecordOutcome: Equatable {
        /// Esc: stop recording, keep the old shortcut.
        case cancel
        /// No ⌘⇧⌥⌃: not a global shortcut, keep waiting.
        case ignore
        case record(UInt16, NSEvent.ModifierFlags, String)
    }

    /// What one key press does while recording. Only ⌘⇧⌥⌃ are kept (caps lock, fn and
    /// device bits would otherwise be stored with the shortcut).
    static func outcome(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, characters: String?) -> RecordOutcome {
        if keyCode == 53 { return .cancel }
        let mods = modifiers.intersection([.command, .shift, .option, .control])
        guard ViewShortcut.isValid(modifiers: mods) else { return .ignore }
        return .record(keyCode, mods, ViewShortcut.keyName(keyCode: keyCode, characters: characters))
    }

    private func stopRecording() {
        isRecording = false
        appState.isRecordingShortcut = false
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }
}
