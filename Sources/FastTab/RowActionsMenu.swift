import SwiftUI

/// The trailing "⋯" trigger shared by command-bar rows (tabs, Stack slots,
/// bookmarks, history and sent links). Replaces the old one-click circle strip
/// so a row has a single, predictable menu instead of a row of icons that grew
/// with every new action. The destructive item is always LAST, after the
/// open/app and housekeeping items, so a mis-aimed click never closes a tab.
///
/// Mouse-only, like the rest of the row's trailing overlay: the row owns the
/// keyboard (↑/↓/Return), so the trigger is never a keyboard stop and never
/// takes focus away from the search field.
struct RowActionsMenu<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Menu {
            content
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.primary.opacity(0.06)))
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More actions")
        .accessibilityLabel("More actions")
    }
}
