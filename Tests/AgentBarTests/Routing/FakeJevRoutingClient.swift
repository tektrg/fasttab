import Foundation
@testable import AgentBar

/// Scripted `JevRoutingClient` for panel-model tests: never touches the network.
final class FakeJevRoutingClient: JevRoutingClient, @unchecked Sendable {
    struct Call: Equatable {
        let text: String
        let candidateIDs: [String]
    }

    private let lock = NSLock()
    private var _outcome: RouteOutcome = .none
    private var _calls: [Call] = []

    var outcome: RouteOutcome {
        get { lock.withLock { _outcome } }
        set { lock.withLock { _outcome = newValue } }
    }
    var calls: [Call] { lock.withLock { _calls } }

    func route(text: String, candidates: [RouteCandidate]) async -> RouteOutcome {
        let picked = outcome
        lock.withLock { _calls.append(Call(text: text, candidateIDs: candidates.map(\.agentID))) }
        return picked
    }
}
