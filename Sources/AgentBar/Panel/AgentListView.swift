import SwiftUI

/// The scrolling section list (rows already grouped, ranked and filtered).
struct AgentListView: View {
    @ObservedObject var model: AgentPanelModel
    let rows: [AgentListRow]
    let fetchedAt: Date

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        rowView(row)
                    }
                }
                .padding(.vertical, AgentPanelMetrics.listVerticalPadding)
            }
            .onChange(of: model.selectedAgentID) {
                guard let id = model.selectedAgentID, id != model.hoverSelectedAgentID,
                      let target = AgentListScrollTarget.id(forSelecting: id, in: rows)
                else { return }
                proxy.scrollTo(target)
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: AgentListRow) -> some View {
        switch row {
        case .header(let section):
            SectionHeaderView(section: section)
        case .chiefPlaceholder(let node, _, let needsYouHint):
            ChiefPlaceholderRowView(node: node, needsYouHint: needsYouHint)
                .modifier(TreeDropTarget(agentID: node.id, isChief: true, treeModel: model.treeModel))
        case .agent(let agent, let nesting):
            let isSelected = model.selectedAgentID == agent.id
            AgentRowView(
                agent: agent,
                nesting: nesting,
                isSelected: isSelected,
                fetchedAt: fetchedAt,
                actionState: model.rowActionStates[agent.id],
                sendingLabel: model.sendingLabel(for: agent),
                sentLabel: model.sentLabel(for: agent),
                highlightedButton: isSelected ? model.highlightedButton : nil,
                isCopied: model.copier.copiedAgentID == agent.id,
                routedNotes: model.routedNotes(for: agent.id),
                treeMenuItems: TreeRowActions.menuItems(forAgentID: agent.id, tree: model.treeModel.tree),
                onPress: { model.press($0, on: agent.id) },
                onCopy: { model.copyIdentity(of: agent) },
                onClearRoutedNote: { model.clearRoutedNote($0, for: agent.id) }
            )
                .onHover { inside in
                    if inside { model.select(agentID: agent.id) }
                }
                .onTapGesture { model.activate(agentID: agent.id) }
                .modifier(TreeDragSource(agentID: agent.id, isChief: isChiefRow(nesting)))
                .modifier(TreeDropTarget(agentID: agent.id, isChief: isChiefRow(nesting), treeModel: model.treeModel))
        }
    }

    private func isChiefRow(_ nesting: AgentRowNesting) -> Bool {
        if case .chief = nesting { return true }
        return false
    }
}

/// A non-chief row can be dragged onto a chief row to attach it there ("Nest under chief" — the
/// list's drag-and-drop equivalent of ⌘] / "Report to…"). A chief row is never itself draggable
/// (two-level rule). Same shape as the old `Tree/AgentTreeRowView.swift`'s `WorkerDragSource`.
private struct TreeDragSource: ViewModifier {
    let agentID: String
    let isChief: Bool

    func body(content: Content) -> some View {
        if isChief {
            content
        } else {
            content.draggable(agentID)
        }
    }
}

/// Only a chief row accepts a drop; dropping an agent id onto one attaches it there. Nothing
/// happens for an agent the hierarchy tree doesn't know about at all (`tree.node(withID:)` nil) —
/// there is no `AgentTreeNode` to attach.
private struct TreeDropTarget: ViewModifier {
    let agentID: String
    let isChief: Bool
    @ObservedObject var treeModel: AgentTreeModel
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        if isChief {
            content
                .background(isTargeted ? Color.accentColor.opacity(0.15) : Color.clear)
                .dropDestination(for: String.self) { items, _ in
                    guard let childID = items.first, let tree = treeModel.tree,
                          let child = tree.node(withID: childID), let parent = tree.node(withID: agentID)
                    else { return false }
                    treeModel.attach(child: child, to: parent)
                    return true
                } isTargeted: { isTargeted = $0 }
        } else {
            content
        }
    }
}
