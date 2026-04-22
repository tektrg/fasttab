import SwiftUI
import AppKit

struct ShortcutRecorderView: View {
    @ObservedObject var store: ShortcutStore
    // AppState.isRecordingShortcut is set so the ContentView local monitor
    // passes all keys through while we're capturing.
    @EnvironmentObject var appState: AppState

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Label("Shortcut", systemImage: "keyboard")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(action: toggleRecording) {
                Text(isRecording ? "Press keys…" : store.displayString)
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .foregroundStyle(isRecording ? Color.accentColor : Color.primary)
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

            if isRecording {
                Text("Esc to cancel")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isRecording)
        .onDisappear { stopRecording() }
    }

    private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        isRecording = true
        appState.isRecordingShortcut = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Escape — cancel
                stopRecording()
                return nil
            }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard ShortcutStore.isValid(modifiers: mods) else { return nil }
            store.update(keyCode: event.keyCode, modifiers: mods, keyName: ShortcutStore.keyName(for: event))
            stopRecording()
            return nil
        }
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
