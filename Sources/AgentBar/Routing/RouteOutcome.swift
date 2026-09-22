import Foundation

/// The result of asking Jev which candidate should get a message. `agentID` on `.picked` is
/// Jev's raw `choice` string, not yet checked against the candidate list — callers must confirm
/// it names a real candidate before acting on it (a model can echo something unexpected).
enum RouteOutcome: Equatable, Sendable {
    case picked(agentID: String, confidence: Double)
    case none
    case failed(String)
}
