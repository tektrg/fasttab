import SwiftUI
import IndieCommandBar

/// "Appearance" tab of Settings: how the command bar looks and how much it shows. The section and
/// its load/save are the shared ones (IndieCommandBar `CommandBarAppearanceSettings`), stored under
/// Fast Tab's keys (`CommandBarAppearance.keys`, old names kept). Saving posts the shared change
/// notice; the bar's own `@AppStorage` fields also see the write.
struct AppearanceSettingsView: View {
    @State private var settings = CommandBarAppearance.load()

    static let options = CommandBarAppearanceOptions(
        offersFitsContent: false,
        rowLimitRange: CommandBarLayout.minQuickOpenItemLimit...CommandBarLayout.maxQuickOpenItemLimit,
        rowLimitTitle: "Quick-open items",
        rowLimitCaption: "Recent tabs shown when FastTab opens with an empty search. Automatically reduced to fit smaller screens.",
        // Default: the bar hugs the edge set in General › Hover to open. Any other choice floats a card there.
        followEdgeTitle: "Follow hover edge"
    )

    var body: some View {
        Form {
            CommandBarAppearanceSection(
                settings: Binding(
                    get: { settings },
                    set: { newValue in
                        settings = newValue
                        newValue.save(to: .standard, keys: CommandBarAppearance.keys)
                    }
                ),
                options: Self.options
            )
        }
        .formStyle(.grouped)
    }
}
