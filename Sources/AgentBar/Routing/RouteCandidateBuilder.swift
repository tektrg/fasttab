import Foundation

/// Turns the shown agent rows into what Jev is asked to choose between. Pure.
enum RouteCandidateBuilder {
    /// Live-agent candidates plus, always, one synthetic "create new" candidate per `WorkerArea` —
    /// so Jev can pick "start a fresh <area> worker" instead of routing to any of them, in the
    /// same single choice, even when no agent is offered at all (an empty dashboard is a valid
    /// moment to spin up a first worker).
    static func candidates(from agents: [AgentSnapshot]) -> [RouteCandidate] {
        liveCandidates(from: agents) + createNewCandidates
    }

    /// Only rows that can actually take a message today (same rule the Message button uses):
    /// live, Claude, addressable by row id, and not already asking something.
    private static func liveCandidates(from agents: [AgentSnapshot]) -> [RouteCandidate] {
        agents
            .filter { RowButtons.usableButtons(for: $0).contains(.message) }
            .map { agent in
                var parts = ["label: \(agent.label)"]
                if let projectName = agent.projectName { parts.append("project: \(projectName)") }
                parts.append("status: \(agent.statusText)")
                return RouteCandidate(agentID: agent.id, summary: parts.joined(separator: " · "))
            }
    }

    private static var createNewCandidates: [RouteCandidate] {
        WorkerArea.allCases.map { RouteCandidate(agentID: $0.candidateID, summary: $0.summary) }
    }
}
