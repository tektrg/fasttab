import SwiftUI
import IndieCommandBar

/// The shared action row: Close · Go to agent · the row's ⋯ items (`AgentActionList`), as one line of
/// capsules (the same `RowActionButtonView` the list rows draw, so confirm/busy/done states match).
/// Used by Focus mode (under the ask column) and the Peek panel — ONE view, never copied.
///
/// Labels never wrap or truncate: each capsule is `fixedSize`; whatever does not fit the width goes
/// into a trailing "More…" menu (`ViewThatFits` over `AgentActionList.candidateCounts`).
struct AgentActionRow: View {
    let items: [AgentActionItem]
    /// The agent's in-flight Done/Close pane state (`AgentPanelModel.rowActionStates`).
    var actionState: RowActionState? = nil
    var fontSize: CGFloat = 11
    var spacing: CGFloat = 6
    let onAction: (AgentAction) -> Void

    var body: some View {
        // The longest prefix that fits on one line wins; the rest go into "More…". `ViewThatFits`
        // measures each candidate at its ideal (unwrapped) width, so a label is never squeezed.
        ViewThatFits(in: .horizontal) {
            ForEach(Array(AgentActionList.candidateCounts(itemCount: items.count)), id: \.self) { count in
                line(visible: count)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func line(visible count: Int) -> some View {
        HStack(spacing: spacing) {
            ForEach(Array(items.prefix(count))) { item in capsule(item) }
            if count < items.count { moreMenu(Array(items.dropFirst(count))) }
        }
        .fixedSize()
    }

    private func capsule(_ item: AgentActionItem) -> some View {
        RowActionButtonView(
            spec: item.spec ?? RowButtonSpec(button: .moreActions, disabledReason: item.isEnabled ? nil : (item.help ?? "")),
            titleOverride: item.spec == nil ? item.title : nil,
            state: actionState,
            isHighlighted: false,
            fontSize: fontSize,
            onPress: { onAction(item.action) }
        )
        .lineLimit(1)
        .fixedSize()
        .help(item.help ?? "")
    }

    private func moreMenu(_ rest: [AgentActionItem]) -> some View {
        Menu {
            ForEach(rest) { item in
                Button(AgentActionList.overflowTitle(of: item, state: actionState)) { onAction(item.action) }
                    .disabled(!AgentActionList.overflowIsEnabled(item, state: actionState))
            }
        } label: {
            Text(AgentActionList.moreTitle).font(.avenir(size: fontSize, weight: .medium)).lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.primary.opacity(0.08)))
    }
}

