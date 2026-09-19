import Foundation
import CommandBarKit

/// Order of agents inside one section.
enum AgentRanking {
    /// - Working / Parked: higher frecency (the user's own past switches, keyed by
    ///   agent id) first; ties, including every never-visited agent, keep the
    ///   status client's order.
    /// - Needs you: agents blocked on a question or permission box come first
    ///   (they cannot go on without the user). Beyond that the client's order is
    ///   urgency, and a snapshot does not expose urgency levels, so ties cannot
    ///   be told apart from real differences: keep the client's order as is.
    /// - Ended: newest first as delivered; frecency would bury the most recent.
    static func ordered(
        _ agents: [AgentSnapshot],
        in section: AgentSection,
        frecency: [String: FrecencyEntry],
        now: Date
    ) -> [AgentSnapshot] {
        switch section {
        case .needsYou:
            return agents.filter { $0.blockedOnYou != nil } + agents.filter { $0.blockedOnYou == nil }
        case .ended:
            return agents
        case .working, .parked:
            return agents.enumerated()
                .map { (index: $0.offset, agent: $0.element, score: score(for: $0.element, frecency, now)) }
                .sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
                .map(\.agent)
        }
    }

    private static func score(for agent: AgentSnapshot, _ frecency: [String: FrecencyEntry], _ now: Date) -> Double {
        frecency[agent.id].map { Frecency.score($0, now: now) } ?? 0
    }
}
