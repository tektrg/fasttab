import SwiftUI
import AppKit

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
            onRecord(event.keyCode, mods, ShortcutStore.keyName(for: event))
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
