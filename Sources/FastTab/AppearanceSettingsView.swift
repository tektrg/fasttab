import SwiftUI
import IndieCommandBar

/// "Appearance" tab of Settings: how the command bar looks. The shared section, load and save
/// (IndieCommandBar `CommandBarAppearanceSection` / `CommandBarAppearanceSettings`), stored under
/// Fast Tab's keys (`CommandBarAppearance.keys`, old names kept), offering `CommandBarAppearance.options`.
/// Saving posts the shared change notice; the bar's own `@AppStorage` fields also see the write.
struct AppearanceSettingsView: View {
    @State private var settings = CommandBarAppearance.load()

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
                options: CommandBarAppearance.options
            )
            // Two separate settings: this Position is for the shortcut and menu bar icon; the hover
            // spot (General › Trigger) always opens the card at that spot.
            Text("Position applies when FastTab opens from the shortcut or the menu bar icon. Opening by hover always shows the card at the hover spot you pick in General › Trigger.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .formStyle(.grouped)
    }
}
