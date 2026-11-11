import SwiftUI
import IndieCommandBar

/// "Appearance" tab: where the panel shows up and how tall it grows. The section is the shared
/// one Fast Tab uses (IndieCommandBar `CommandBarAppearanceSection`); Agent Bar keeps its own
/// stored copy (`AgentListSettings.appearanceKeys`). Applies live.
struct AppearanceSettingsView: View {
    @ObservedObject var settings: AgentBarSettings

    var body: some View {
        Form {
            CommandBarAppearanceSection(
                settings: Binding(
                    get: { settings.list.appearance },
                    set: { newValue in settings.updateList { $0.appearance = newValue } }
                ),
                options: CommandBarAppearanceOptions(
                    offersBackground: false,
                    offersRowStyle: false,
                    rowLimitRange: AgentListSettings.maxVisibleRowsRange,
                    rowLimitCaption: "Fit to content: the panel is only as tall as its rows, up to this many. Fixed height: always this tall."
                ),
                title: "Panel"
            )
        }
        .formStyle(.grouped)
    }
}
