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
                highlightedButton: isSelected ? model.highlightedButton : nil,
                onPress: { model.press($0, on: agent.id) }
            )
                .onHover { inside in
                    if inside { model.select(agentID: agent.id) }
                }
                .onTapGesture { model.activate(agentID: agent.id) }
        }
    }
}
