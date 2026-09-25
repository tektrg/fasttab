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
                guard let id = model.selectedAgentID else { return }
                proxy.scrollTo("agent-\(id)")
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: AgentListRow) -> some View {
        switch row {
        case .header(let section):
            SectionHeaderView(section: section)
        case .agent(let agent):
            let isSelected = model.selectedAgentID == agent.id
            AgentRowView(
                agent: agent,
                isSelected: isSelected,
                fetchedAt: fetchedAt,
                actionState: model.rowActionStates[agent.id],
                sendingLabel: model.sendingLabel(for: agent),
                sentLabel: model.sentLabel(for: agent),
                highlightedButton: isSelected ? model.highlightedButton : nil,
                isCopied: model.copier.copiedAgentID == agent.id,
                routedNotes: model.routedNotes(for: agent.id),
                onPress: { model.press($0, on: agent.id) },
                onCopy: { model.copyIdentity(of: agent) },
                onClearRoutedNote: { model.clearRoutedNote($0, for: agent.id) }
            )
                .onHover { inside in
                    if inside { model.select(agentID: agent.id) }
                }
                .onTapGesture { model.activate(agentID: agent.id) }
        }
    }
}
