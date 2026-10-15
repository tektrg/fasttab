import Foundation

/// Spots agents in Needs you that have just started asking the user something (a question or a permission
/// box, however AgentBar came to know: dashboard, blocker memory or its own pane read; or a Claude Desktop
/// end-of-turn wrap_up question). Pure.
///
/// One report per question per stay in Needs you, keyed by `AgentSnapshot.pendingQuestionKey`: a blocker
/// already reported keeps quiet while the agent stays, even if it flaps; a wrap_up question is keyed by its
/// ask, so the same one on every re-poll reports once and a different one reports again. Everything about an
/// agent is forgotten when it leaves Needs you. Like `NeedsYouArrivalDetector`, the first reading after a
/// start or a dead feed is only a baseline: questions already pending then are not "new".
struct BlockedEpisodeTracker: Equatable, Sendable {
    private struct Announced: Hashable, Sendable {
        let agentID: String
        let questionKey: String
    }

    private var announced: Set<Announced>?

    /// `needsYou` is nil when there is no trustworthy reading. True when an agent newly asks the user something.
    mutating func observe(_ needsYou: [AgentSnapshot]?) -> Bool {
        guard let needsYou else {
            announced = nil
            return false
        }
        let asking = Set(needsYou.compactMap { agent in
            agent.pendingQuestionKey.map { Announced(agentID: agent.id, questionKey: $0) }
        })
        let stillPresent = Set(needsYou.map(\.id))
        let previous = announced
        announced = (previous ?? []).filter { stillPresent.contains($0.agentID) }.union(asking)
        guard let previous else { return false }
        return !asking.subtracting(previous).isEmpty
    }
}
