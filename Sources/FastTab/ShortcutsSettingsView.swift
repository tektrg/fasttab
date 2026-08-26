import SwiftUI

/// "Shortcuts" tab of Settings: the global keyboard shortcut that opens FastTab.
struct ShortcutsSettingsView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var shortcutStore = ShortcutStore.shared

    var body: some View {
        Form {
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
        }
        .formStyle(.grouped)
    }
}
