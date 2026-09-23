import Foundation

/// The result of asking Jev which candidate should get a message. `agentID` on `.picked` is
/// Jev's raw `choice` string, not yet checked against the candidate list — callers must confirm
/// it names a real candidate before acting on it (a model can echo something unexpected).
enum RouteOutcome: Equatable, Sendable {
    case picked(agentID: String, confidence: Double)
    /// Jev chose to start a brand-new AptusFit worker instead of routing to any live agent.
    /// `JevRoutingClient` implementations never produce this directly — the wire protocol only
    /// ever answers `.picked` with a candidate id; `resolved(from:)` is what turns a `.picked`
    /// naming a `WorkerArea.candidateID` ("new:<alias>") into this case.
    case createNew(area: WorkerArea, confidence: Double)
    case none
    case failed(String)

    /// Reinterprets a `.picked` outcome whose id names one of `RouteCandidateBuilder`'s synthetic
    /// "create new" candidates as `.createNew`; every other outcome (including an already-resolved
    /// `.createNew`) passes through unchanged. Pure; `AgentPanelModel.finishRouting` calls this
    /// once, right after the network reply, before acting on it.
    static func resolved(from outcome: RouteOutcome) -> RouteOutcome {
        guard case .picked(let agentID, let confidence) = outcome, let area = WorkerArea.from(candidateID: agentID) else {
            return outcome
        }
        return .createNew(area: area, confidence: confidence)
    }
}
