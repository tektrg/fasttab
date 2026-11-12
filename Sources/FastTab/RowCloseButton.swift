import SwiftUI

/// One-click close/remove button shown beside the row's ⋯ menu (IndieCommandBar
/// `RowActionMenu`, actions from `FastTabRowMenu`) (2 buttons per
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
