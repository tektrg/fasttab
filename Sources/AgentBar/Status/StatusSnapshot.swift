import Foundation

/// Whether the status data can be trusted right now.
enum StatusFeedHealth: Equatable, Sendable {
    case ok
    /// The dashboard is unreachable, or a feed AgentBar depends on is broken or
    /// stale. The reason is plain English for display.
    case down(reason: String)

    var isDown: Bool {
        if case .down = self { return true }
        return false
    }
}

/// Everything the UI needs to render one refresh of the agent list.
struct StatusSnapshot: Equatable, Sendable {
    /// Ordered by section (needs-you first), ended newest first. Always empty
    /// when `health` is `.down`, so a dead feed can never look like "all calm".
    let agents: [AgentSnapshot]
    let health: StatusFeedHealth
    let fetchedAt: Date
    /// False when the slow delivery-board feed is missing or stale: the Ended
    /// section is then empty and unpushed markers are absent, not "none".
    let boardIsCurrent: Bool
    /// Who-reports-to-whom, if this dashboard sent it. Nil means the feature is unavailable (an
    /// older dashboard, or a broken/absent field) — `AgentTreeModel` reads it that way, never as
    /// an empty tree (a genuinely empty tree still decodes to a non-nil `AgentTree`).
    let agentTree: AgentTree?

    /// Memberwise init with `agentTree` defaulted to nil, so existing call sites (mostly test
    /// fixtures built before this field existed) don't all need updating for a field they don't care about.
    init(agents: [AgentSnapshot], health: StatusFeedHealth, fetchedAt: Date, boardIsCurrent: Bool, agentTree: AgentTree? = nil) {
        self.agents = agents
        self.health = health
        self.fetchedAt = fetchedAt
        self.boardIsCurrent = boardIsCurrent
        self.agentTree = agentTree
    }

    static func down(reason: String, at date: Date) -> StatusSnapshot {
        StatusSnapshot(agents: [], health: .down(reason: reason), fetchedAt: date, boardIsCurrent: false, agentTree: nil)
    }

    func replacingAgents(_ newAgents: [AgentSnapshot]) -> StatusSnapshot {
        StatusSnapshot(agents: newAgents, health: health, fetchedAt: fetchedAt, boardIsCurrent: boardIsCurrent, agentTree: agentTree)
    }

    func agents(in section: AgentSection) -> [AgentSnapshot] {
        agents.filter { $0.section == section }
    }
}
