import SwiftUI
import IndieCommandBar

/// "Appearance" tab of Settings: how the command bar looks. Load/save are the shared ones
/// (IndieCommandBar `CommandBarAppearanceSettings`), stored under Fast Tab's keys
/// (`CommandBarAppearance.keys`, old names kept). Saving posts the shared change notice; the
/// bar's own `@AppStorage` fields also see the write.
///
/// The section is Fast Tab's own rather than the shared `CommandBarAppearanceSection`: that
/// one always draws a row-count stepper, and Fast Tab has no row count any more — every open
/// lists every tab (the "Quick-open items" setting was removed 2026-11-14). Swap back once
/// the shared section can hide its stepper.
struct AppearanceSettingsView: View {
    @State private var settings = CommandBarAppearance.load()

    var body: some View {
        Form {
            FastTabAppearanceSection(settings: Binding(
                get: { settings },
                set: { newValue in
                    settings = newValue
                    newValue.save(to: .standard, keys: CommandBarAppearance.keys)
                }
            ))
        }
        .formStyle(.grouped)
    }
}

/// Accent, Position (default: follow the hover edge set in General › Hover to open; any
/// other choice floats a card there), Background and Result rows. No Size picker (the bar
/// sizes itself) and no row count.
struct FastTabAppearanceSection: View {
    @Binding var settings: CommandBarAppearanceSettings

    static let followEdgeTitle = "Follow hover edge"

    var body: some View {
        Section("Appearance") {
            Picker("Accent colour", selection: $settings.accent) {
                ForEach(CommandBarAccent.allCases) { accent in
                    Label {
                        Text(accent.displayName)
                    } icon: {
                        Image(systemName: "circle.fill").foregroundStyle(accent.color)
                    }
                    .tag(accent)
                }
            }
            .pickerStyle(.menu)
            Picker("Position", selection: $settings.position) {
                Text(Self.followEdgeTitle).tag(CommandBarPlacement?.none)
                Divider()
                ForEach(CommandBarPlacement.allCases) { Text($0.displayName).tag(CommandBarPlacement?.some($0)) }
            }
            .pickerStyle(.menu)
            Toggle("Background", isOn: $settings.background)
            Picker("Result rows", selection: $settings.rowStyle) {
                ForEach(ResultRowStyle.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
        }
    }
}
