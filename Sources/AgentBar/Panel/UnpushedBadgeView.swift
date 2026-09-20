import SwiftUI

/// Small "commits not pushed" marker; the dashboard's own wording is the tooltip.
struct UnpushedBadgeView: View {
    let detail: String?

    var body: some View {
        Text("↑ unpushed")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(WarningTextColor.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.orange.opacity(0.15)))
            .help(detail ?? "Has commits that are not pushed")
    }
}
