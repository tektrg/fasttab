import SwiftUI
import CommandBarKit
import IndieEdgeReveal

/// "General" tab of Settings: how the app starts and how it's triggered.
struct GeneralSettingsView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var launchAtLogin = LaunchAtLoginService.shared
    @ObservedObject private var edgeReveal = EdgeRevealStore.shared
    @ObservedObject private var viewStore = CommandBarViewStore.shared
    @ObservedObject private var myOrderStore = MyOrderStore.shared
    @ObservedObject private var rowSwipeStore = RowSwipeGestureStore.shared

    // Settings stays reachable with the icon and the panel both off: the
    // bar itself still opens from the global shortcut (or a hover edge),
    // and hiding the helper panel leaves a gear floating at the bar's
    // bottom-right corner — so neither toggle needs to guard the other.
    @AppStorage(CommandBarAppearance.menuBarIconVisibleKey) private var showMenuBarIcon: Bool = true
    @AppStorage(CommandBarAppearance.helperPanelVisibleKey) private var showHelperPanel: Bool = true
    @AppStorage(CommandBarAppearance.guideBarVisibleKey) private var showGuideBar: Bool = true

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

                Toggle("Show menu bar icon", isOn: $showMenuBarIcon)

                if !showMenuBarIcon {
                    Text("The global shortcut still opens FastTab. Reopen this settings window from the gear at the bottom-right corner of the command bar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Toggle("Show helper panel", isOn: $showHelperPanel)

                Text("The shortcut recorder and the gear that reopens these settings, shown at the bottom of the command bar. Hiding it leaves a smaller gear floating at the bar's bottom-right corner.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Hiding just the hints keeps the shortcut recorder and its
                // gear, so this is safe with the menu bar icon off too.
                Toggle("Show guide bar", isOn: $showGuideBar)
                    .disabled(!showHelperPanel)

                Text("The row of hints and the tab-count status shown at the bottom of the command bar. Safe to hide with the menu bar icon off.")
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
                    Picker("Hover opens", selection: Binding(
                        get: { viewStore.hoverDefaultView },
                        set: { viewStore.setHoverDefaultView($0) }
                    )) {
                        ForEach(CommandBarView.allCases, id: \.self) { view in
                            Text(view.displayName).tag(view)
                        }
                    }
                    .pickerStyle(.menu)

                    Text("Hover the \(edgeReveal.style.displayName.lowercased()) to open FastTab directly into \(viewStore.hoverDefaultView.displayName). Uses an invisible hover zone there, no background mouse tracking.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Stack") {
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

                Text("Closed pinned tabs in Stack remain as reopenable ghost rows for this long before being removed. Set to 0 to keep forever.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Gestures") {
                Toggle("Swipe gestures on rows (Deprecated)", isOn: $rowSwipeStore.isEnabled)

                Text("Swipe left to remove, swipe right to copy link. Deprecated: conflicts with trackpad swipe to switch views. When disabled (default), swiping horizontally anywhere switches between Recents and Stack.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}
