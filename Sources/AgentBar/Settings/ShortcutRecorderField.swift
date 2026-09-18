import SwiftUI
import AppKit

/// Click-to-record shortcut field (adapted from FastTab's `ShortcutRecorderView`).
/// While recording, the next key press with at least one modifier becomes the
/// shortcut; Esc cancels. The host suspends the global shortcut for the
/// duration (`onRecordingChange`), otherwise pressing the current shortcut
/// would trigger it instead of being recorded.
struct ShortcutRecorderField: View {
    let displayString: String
    let onRecord: (AgentHotkeyConfig) -> Void
    /// A key was pressed with no modifier; explain why nothing happened.
    let onKeyWithoutModifier: () -> Void
    let onRecordingChange: (Bool) -> Void

    @State private var isRecording = false
    @State private var keyMonitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggleRecording) {
                Text(isRecording ? "Press keys…" : displayString)
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .foregroundStyle(isRecording ? Color.accentColor : Color.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule(style: .continuous)
                            .fill(.ultraThinMaterial)
                            .overlay(
                                Capsule(style: .continuous)
                                    .strokeBorder(isRecording ? Color.accentColor.opacity(0.65) : Color.primary.opacity(0.2), lineWidth: 1)
                            )
                    )
            }
            .buttonStyle(.plain)
            .help("Click, then press the new shortcut")

            if isRecording {
                Text("Esc to cancel")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isRecording)
        .onDisappear(perform: stopRecording)
        // Clicking into another app while recording must not leave the shortcut suspended.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            stopRecording()
        }
    }

    private static let escapeKeyCode: UInt16 = 53

    private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        onRecordingChange(true)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == Self.escapeKeyCode {
                stopRecording()
                return nil
            }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard let config = AgentHotkeyConfig.recorded(
                keyCode: event.keyCode, modifiers: modifiers, keyName: RecordedKeyName.name(for: event)
            ) else {
                onKeyWithoutModifier()
                return nil
            }
            stopRecording()
            onRecord(config)
            return nil
        }
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        onRecordingChange(false)
    }
}
