import SwiftUI
import CommandBarKit

/// "General" tab of Settings: how the app starts and how it's triggered.
struct GeneralSettingsView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var launchAtLogin = LaunchAtLoginService.shared
    @ObservedObject private var edgeReveal = EdgeRevealStore.shared
    @ObservedObject private var myOrderStore = MyOrderStore.shared
    @ObservedObject private var rowSwipeStore = RowSwipeGestureStore.shared

    // The gear icon that opens this window lives in the helper panel, and
    // "Settings…" lives in the menu bar menu — each is the other's fallback.
    // Refusing to disable the second one keeps at least one path back into
    // Settings once the icon and panel are both off.
    @AppStorage(CommandBarAppearance.menuBarIconVisibleKey) private var showMenuBarIcon: Bool = true
    @AppStorage(CommandBarAppearance.helperPanelVisibleKey) private var showHelperPanel: Bool = true

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
                        .foregroundStyle(.secondary)
                }

                Toggle("Show menu bar icon", isOn: Binding(
                    get: { showMenuBarIcon },
                    set: { newValue in
                        guard newValue || showHelperPanel else { return }
                        showMenuBarIcon = newValue
                    }
                ))

                if !showMenuBarIcon {
                    Text("The global shortcut still opens FastTab. Reopen this settings window from the helper panel's gear icon.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Toggle("Show helper panel", isOn: Binding(
                    get: { showHelperPanel },
                    set: { newValue in
                        guard newValue || showMenuBarIcon else { return }
                        showHelperPanel = newValue
                    }
                ))

                Text("The row of hints and the shortcut recorder shown at the bottom of the command bar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Trigger") {
                Picker("Hover to open", selection: Binding(
                    get: { edgeReveal.style },
                    set: { edgeReveal.update($0) }
                )) {
                    ForEach(EdgeRevealStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .pickerStyle(.menu)

                if edgeReveal.style != .off {
                    Text("Hover the \(edgeReveal.style.displayName.lowercased()) to open FastTab directly into My Order. Runs a background mouse-position listener whenever this isn't Off.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("My Order") {
                Stepper(
                    value: Binding(
                        get: { myOrderStore.ghostExpiryDays },
                        set: { myOrderStore.setGhostExpiryDays($0) }
                    ),
                    in: 0...30
                ) {
                    HStack {
                        Text("Ghost expiry")
                        Spacer()
                        Text(myOrderStore.ghostExpiryDays == 0 ? "Never" : "\(myOrderStore.ghostExpiryDays) days")
                            .foregroundStyle(.secondary)
                    }
                }

                Text("Closed pinned tabs in My Order remain as reopenable ghost rows for this long before being removed. Set to 0 to keep forever.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Gestures") {
                Toggle("Swipe gestures on rows (Deprecated)", isOn: $rowSwipeStore.isEnabled)

                Text("Swipe left to remove, swipe right to copy link. Deprecated: conflicts with trackpad swipe to switch views. When disabled (default), swiping horizontally anywhere switches tabs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}
