import SwiftUI
import IndieCommandBar

/// "Appearance" tab of Settings: how the command bar looks and how much it shows. The section is
/// the shared one (IndieCommandBar `CommandBarAppearanceSection`), stored under Fast Tab's own keys.
struct AppearanceSettingsView: View {
    @AppStorage(CommandBarAppearance.outerPanelKey) private var outerPanelEnabled: Bool = true
    @AppStorage(CommandBarAppearance.resultRowStyleKey) private var resultRowStyle: ResultRowStyle = .minimal
    @AppStorage(CommandBarAppearance.quickOpenItemLimitKey) private var quickOpenItemLimit: Int = 5
    @AppStorage(CommandBarAppearance.accentKey) private var accent: CommandBarAccent = .system

    var body: some View {
        Form {
            CommandBarAppearanceSection(
                settings: Binding(
                    get: {
                        CommandBarAppearanceSettings(background: outerPanelEnabled, rowStyle: resultRowStyle, rowLimit: quickOpenItemLimit, accent: accent)
                    },
                    set: { newValue in
                        outerPanelEnabled = newValue.background
                        resultRowStyle = newValue.rowStyle
                        quickOpenItemLimit = newValue.rowLimit
                        accent = newValue.accent
                    }
                ),
                options: CommandBarAppearanceOptions(
                    offersPlacement: false,   // Fast Tab's position follows General › Hover to open
                    offersFitsContent: false,
                    rowLimitRange: CommandBarLayout.minQuickOpenItemLimit...CommandBarLayout.maxQuickOpenItemLimit,
                    rowLimitTitle: "Quick-open items",
                    rowLimitCaption: "Recent tabs shown when FastTab opens with an empty search. Automatically reduced to fit smaller screens."
                )
            )
        }
        .formStyle(.grouped)
    }
}
