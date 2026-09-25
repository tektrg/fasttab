import SwiftUI

/// A dimmed, non-interactive anchor row for a chief whose own row lives in a different status
/// section (or isn't shown at all right now) — drawn only so this section's workers have something
/// to nest under (`AgentListGrouping.chiefPlaceholder`, PO's "Nest inside each section" decision,
/// 2026-09-25). Deliberately NOT drawn like a real `AgentRowView` (no status dot, no age, no
/// buttons, always dimmed) so it never reads as a duplicate live chief row. The only interaction it
/// accepts is a drop (`TreeDropTarget` in `AgentListView`, keyed by the chief's own tree id) —
/// dragging a worker onto it attaches to that chief exactly like dropping onto the chief's real row
/// would. Never selectable: `AgentListRow.selectableAgentID` is nil for `.chiefPlaceholder`, so
/// arrow keys skip straight over it (the simplest fit for `AgentSelection`, which only ever walks a
/// flat list of real, focusable agent ids — jumping the keyboard selection to the chief's real row
/// elsewhere would need that row to always be a valid, currently-shown target, which it may not be).
struct ChiefPlaceholderRowView: View {
    let node: AgentTreeNode
    let needsYouHint: Int

    var body: some View {
        HStack(spacing: 8) {
            Text(node.label)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
            Text("chief")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            if needsYouHint > 0 {
                Text("\(needsYouHint) needs you")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.red.opacity(0.7))
            }
            if let machineBadge = node.machineBadge { MachineBadgeView(text: machineBadge) }
            Spacer(minLength: 8)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: AgentPanelMetrics.rowHeight)
        .padding(.horizontal, 10)
        .opacity(0.6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(node.label), chief")
    }
}
