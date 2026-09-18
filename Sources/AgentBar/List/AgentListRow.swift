import Foundation

/// One line of the switcher list: a section header or an agent.
enum AgentListRow: Equatable, Identifiable {
    case header(AgentSection)
    case agent(AgentSnapshot)

    var id: String {
        switch self {
        case .header(let section): "section-\(section.rawValue)"
        case .agent(let agent): "agent-\(agent.id)"
        }
    }

    /// The agent id when this row can be selected and activated. Headers and
    /// unfocusable rows (ended sessions, anything without a live pane) are
    /// skipped by arrow keys and ignore clicks.
    var selectableAgentID: String? {
        guard case .agent(let agent) = self, agent.canFocus else { return nil }
        return agent.id
    }
}

/// What the panel body shows. The states are mutually exclusive and ordered by
/// priority: a dead feed must never be mistaken for an empty list.
enum AgentListState: Equatable {
    /// No snapshot has arrived yet.
    case connecting
    case feedDown(reason: String)
    /// Healthy feed, genuinely zero agents.
    case noAgents
    /// Agents exist but the search query excludes all of them.
    case noMatches
    case list
}

/// Everything the panel view needs to render, derived purely from the latest
/// snapshot + the search text + frecency.
struct AgentListPresentation: Equatable {
    let state: AgentListState
    /// Headers and agents in display order; empty unless `state == .list`.
    let rows: [AgentListRow]
    /// True when the slow delivery-board feed is stale: Ended rows and
    /// unpushed markers are then missing rather than "none".
    let showsBoardNote: Bool

    static let connecting = AgentListPresentation(state: .connecting, rows: [], showsBoardNote: false)

    var selectableAgentIDs: [String] {
        rows.compactMap(\.selectableAgentID)
    }

    var agents: [AgentSnapshot] {
        rows.compactMap { row in
            if case .agent(let agent) = row { return agent }
            return nil
        }
    }
}
