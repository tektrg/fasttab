import SwiftUI

/// The panel's "Focus" button (next to the search box): opens Focus mode, with the number of agents
/// that need you. Disabled with "Nothing needs you" when there are none. ⌘F does the same.
struct FocusButton: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "rectangle.inset.filled")
                    .font(.system(size: 11, weight: .medium))
                Text("Focus")
                    .font(.avenir(size: 12, weight: .semibold))
                if count > 0 {
                    Text("\(count)")
                        .font(.avenir(size: 11, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .background(Capsule().fill(FocusPalette.accent))
                }
            }
            .foregroundStyle(count > 0 ? .primary : .secondary)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .disabled(count == 0)
        .help(count > 0 ? "Answer the agents that need you, one at a time (⌘F)" : "Nothing needs you")
        .accessibilityLabel(count > 0 ? "Focus, \(count) need you" : "Focus, nothing needs you")
    }
}
