import SwiftUI
import CommandBarKit

/// "Shortcuts" tab of Settings: global keyboard shortcuts that open FastTab.
struct ShortcutsSettingsView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var shortcutStore = ShortcutStore.shared
    @ObservedObject private var viewStore = CommandBarViewStore.shared

    var body: some View {
        Form {
            Section("Primary Shortcut") {
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

                Picker("Default view", selection: Binding(
                    get: { viewStore.defaultView },
                    set: { viewStore.setDefaultView($0) }
                )) {
                    ForEach(CommandBarView.allCases, id: \.self) { view in
                        Text(view.displayName).tag(view)
                    }
                }
            }

            Section("Direct View Shortcuts") {
                Text("Open FastTab directly to a specific view.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                viewShortcutRow(for: .recents)
                viewShortcutRow(for: .stack)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func viewShortcutRow(for view: CommandBarView) -> some View {
        let current = shortcutStore.shortcut(for: view)
        HStack {
            Label(view.displayName, systemImage: view.iconName)
            Spacer()
            ShortcutRecorderView(
                displayString: current?.displayString ?? "None",
                onRecord: { keyCode, mods, name in
                    let newShortcut = ViewShortcut(
                        keyCode: keyCode,
                        modifiers: mods.rawValue,
                        keyName: name
                    )
                    shortcutStore.updateViewShortcut(for: view, shortcut: newShortcut)
                },
                onClear: current != nil ? {
                    shortcutStore.updateViewShortcut(for: view, shortcut: nil)
                } : nil
            )
        }
    }
}
