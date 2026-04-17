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
        HStack(spacing: 6) {
            Text("Shortcut:")
                .font(.caption)
                .foregroundColor(.secondary)

            Button(action: toggleRecording) {
                Text(isRecording ? "Press keys…" : store.displayString)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(isRecording ? .accentColor : .primary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(
                                isRecording ? Color.accentColor : Color.secondary.opacity(0.35),
                                lineWidth: 1
                            )
                    )
            }
            .buttonStyle(.plain)

            if isRecording {
                Text("Esc to cancel")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
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
