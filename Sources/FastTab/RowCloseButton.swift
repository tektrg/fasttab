import SwiftUI

/// The trailing "⋯" trigger shared by command-bar rows (tabs, Stack slots,
/// bookmarks, history and sent links). Replaces the old one-click circle strip
/// so a row has a single, predictable menu instead of a row of icons that grew
/// with every new action. Close/remove is NOT in this menu: it is the separate
/// `RowCloseButton` beside the trigger, so closing stays one click.
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

/// One-click close/remove button shown beside the "⋯" trigger (2 buttons per
/// row). `keepsGhost` swaps the ✕ for a "−" on pinned live tabs, which close
/// into a ghost instead of disappearing. Same mouse-only rules as the menu.
struct RowCloseButton: View {
    var keepsGhost: Bool = false
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: keepsGhost ? "minus" : "xmark")
                .font(.system(size: keepsGhost ? 11 : 10, weight: keepsGhost ? .bold : .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.primary.opacity(0.06)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}
