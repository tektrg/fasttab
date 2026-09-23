import Foundation
import Testing
@testable import AgentBar

struct RouteOutcomeTests {
    @Test func aPickedLiveAgentIDPassesThroughUnchanged() {
        let outcome = RouteOutcome.picked(agentID: "w1", confidence: 0.9)
        #expect(RouteOutcome.resolved(from: outcome) == outcome)
    }

    @Test func aPickedCreateNewIDResolvesToCreateNewWithTheMatchingArea() {
        let outcome = RouteOutcome.picked(agentID: "new:backend", confidence: 0.7)
        #expect(RouteOutcome.resolved(from: outcome) == .createNew(area: .backend, confidence: 0.7))
    }

    @Test func anUnknownNewPrefixedIDPassesThroughUnchanged() {
        // "new:" but not a real WorkerArea rawValue — never silently coerced to some area.
        let outcome = RouteOutcome.picked(agentID: "new:not-a-real-area", confidence: 0.5)
        #expect(RouteOutcome.resolved(from: outcome) == outcome)
    }

    @Test func noneAndFailedPassThroughUnchanged() {
        #expect(RouteOutcome.resolved(from: .none) == .none)
        #expect(RouteOutcome.resolved(from: .failed("x")) == .failed("x"))
    }

    @Test func anAlreadyResolvedCreateNewIsIdempotent() {
        let outcome = RouteOutcome.createNew(area: .meta, confidence: 0.3)
        #expect(RouteOutcome.resolved(from: outcome) == outcome)
    }
}

struct WorkerAreaTests {
    @Test func candidateIDRoundTripsThroughFrom() {
        for area in WorkerArea.allCases {
            #expect(WorkerArea.from(candidateID: area.candidateID) == area)
        }
    }

    @Test func aLiveAgentIDNeverParsesAsAWorkerArea() {
        #expect(WorkerArea.from(candidateID: "some-pane-id") == nil)
        #expect(WorkerArea.from(candidateID: "") == nil)
    }

    @Test func repoAliasIsTheCanonicalRawValue() {
        #expect(WorkerArea.fe.repoAlias == "fe")
        #expect(WorkerArea.backend.repoAlias == "backend")
        #expect(WorkerArea.landing.repoAlias == "landing")
        #expect(WorkerArea.meta.repoAlias == "meta")
        #expect(WorkerArea.skills.repoAlias == "skills")
    }
}
