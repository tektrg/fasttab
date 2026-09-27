import Foundation

/// Which agents the user has parked. A live agent that is not working is
/// "Needs you" until the user clears it: Done ends it, Park sets it aside into
/// the Parked section. A parked agent comes back to Needs you once it has been
/// seen working again (it has new work to report), and forgotten agents are
/// pruned. Keyed by `AgentSnapshot.id` (session id, else pane id).
struct TriageState: Equatable, Sendable {
    private(set) var parkedIDs: Set<String>

    static let empty = TriageState(parkedIDs: [])

    init(parkedIDs: Set<String>) {
        self.parkedIDs = parkedIDs
    }

    func isParked(_ id: String) -> Bool {
        parkedIDs.contains(id)
    }

    mutating func park(_ id: String) {
        parkedIDs.insert(id)
    }

    mutating func unpark(_ id: String) {
        parkedIDs.remove(id)
    }

    /// Reconciles with a fresh, healthy status snapshot (`agents` before
    /// `applying`): an agent seen working is no longer parked, and an agent
    /// that is no longer live is forgotten. Returns whether anything changed.
    /// Do not call with the agents of a `.down` snapshot: an unreachable
    /// dashboard would look like every agent vanishing.
    @discardableResult
    mutating func observe(_ agents: [AgentSnapshot]) -> Bool {
        let live = agents.filter { $0.section != .ended && $0.section != .sleeping }
        let liveIDs = Set(live.map(\.id))
        let workingIDs = Set(live.filter { $0.section == .working }.map(\.id))
        let kept = parkedIDs.filter { liveIDs.contains($0) && !workingIDs.contains($0) }
        guard kept != parkedIDs else { return false }
        parkedIDs = kept
        return true
    }

    /// The agents as the user sees them: parked ones (needs-you rows, never
    /// working ones) move to the Parked section. Order kept.
    func applying(to agents: [AgentSnapshot]) -> [AgentSnapshot] {
        guard !parkedIDs.isEmpty else { return agents }
        return agents.map { agent in
            agent.section == .needsYou && parkedIDs.contains(agent.id) ? agent.placed(in: .parked) : agent
        }
    }
}
