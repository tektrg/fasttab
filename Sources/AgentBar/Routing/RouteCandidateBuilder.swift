import Foundation

/// Turns the shown agent rows into what Jev is asked to choose between. Pure.
enum RouteCandidateBuilder {
    /// Only rows that can actually take a message today (same rule the Message button uses):
    /// live, Claude, addressable by row id, and not already asking something. Empty when no agent
    /// qualifies (`OpenRouterJevClient.route` returns `.none` without a network call for that case).
    static func candidates(from agents: [AgentSnapshot]) -> [RouteCandidate] {
        agents
            .filter { RowButtons.usableButtons(for: $0).contains(.message) }
            .map { agent in
                var parts = ["label: \(agent.label)"]
                if let projectName = agent.projectName { parts.append("project: \(projectName)") }
                parts.append("status: \(agent.statusText)")
                return RouteCandidate(agentID: agent.id, summary: parts.joined(separator: " · "))
            }
    }
}
