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

    static func down(reason: String, at date: Date) -> StatusSnapshot {
        StatusSnapshot(agents: [], health: .down(reason: reason), fetchedAt: date, boardIsCurrent: false)
    }

    func replacingAgents(_ newAgents: [AgentSnapshot]) -> StatusSnapshot {
        StatusSnapshot(agents: newAgents, health: health, fetchedAt: fetchedAt, boardIsCurrent: boardIsCurrent)
    }

    func agents(in section: AgentSection) -> [AgentSnapshot] {
        agents.filter { $0.section == section }
    }
}
