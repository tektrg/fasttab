import SwiftUI

/// "Appearance" tab of Settings: how the command bar looks and how much it shows.
struct AppearanceSettingsView: View {
    @AppStorage(CommandBarAppearance.outerPanelKey) private var outerPanelEnabled: Bool = true
    @AppStorage(CommandBarAppearance.resultRowStyleKey) private var resultRowStyle: ResultRowStyle = .minimal
    @AppStorage(CommandBarAppearance.quickOpenItemLimitKey) private var quickOpenItemLimit: Int = 5

    var body: some View {
        Form {
            Section("Appearance") {
                Toggle("Background", isOn: $outerPanelEnabled)

                Picker("Result rows", selection: $resultRowStyle) {
                    ForEach(ResultRowStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .pickerStyle(.segmented)

                Stepper(
                    "Quick-open items: \(quickOpenItemLimit)",
                    value: $quickOpenItemLimit,
                    in: CommandBarLayout.minQuickOpenItemLimit...CommandBarLayout.maxQuickOpenItemLimit
                )

                Text("Recent tabs shown when FastTab opens with an empty search. Automatically reduced to fit smaller screens.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}
