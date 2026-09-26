import Foundation
import Testing
import CommandBarKit
@testable import AgentBar

struct RouteCandidateBuilderTests {
    typealias F = AgentListFixtures

    private static func visited(daysAgo: Double, count: Double = 1) -> FrecencyEntry {
        let when = F.now.addingTimeInterval(-daysAgo * 86_400)
        return FrecencyEntry(count: count, lastVisit: when, cachedScore: count, cachedScoreAt: when)
    }

    // MARK: Sessions — unchanged eligibility rule, new (persona-prefixed, project-less) summary shape

    @Test func onlyMessageEligibleRowsBecomeLiveCandidates() {
        let working = F.agent("w", label: "worker", section: .working)
        let ended = F.agent("e", section: .ended)
        let blocked = F.agent("b", section: .working)
        var stillBlocked = blocked
        stillBlocked.blocker = .permission
        let notHooked = F.agent("s", section: .working, hasHookData: false)

        let candidates = RouteCandidateBuilder.candidates(from: [working, ended, stillBlocked, notHooked])
        #expect(candidates.map(\.agentID) == ["w"])
    }

    @Test func sessionSummaryHasNoPersonaLabelStatusAndWorkingOn() {
        let agent = F.agent("w", label: "worker-2", section: .working, statusText: "Working", excerpt: "fix the thing")
        let candidates = RouteCandidateBuilder.candidates(from: [agent])
        #expect(candidates.first?.summary == "no persona · worker-2 · Working · working on: fix the thing")
    }

    @Test func aMissingPromptExcerptIsLeftOutRatherThanShowingAPlaceholder() {
        let agent = F.agent("w", label: "worker-2", section: .working, statusText: "Working")
        let candidates = RouteCandidateBuilder.candidates(from: [agent])
        #expect(candidates.first?.summary == "no persona · worker-2 · Working")
    }

    @Test func aSessionOwnedByAPersonaIsPrefixedWithItsNameInsteadOfNoPersona() {
        let agent = F.agent("w", label: "worker-2", section: .working, statusText: "Working")
        let persona = PersonaFixtures.persona("chief-aptus", sessionRowIds: ["w"])
        let candidates = RouteCandidateBuilder.candidates(from: [agent], personas: [persona])
        #expect(candidates.last?.summary == "chief-aptus · worker-2 · Working")
    }

    @Test func aPersonasMainSessionIsAlsoPrefixed() {
        let agent = F.agent("w", label: "worker-2", section: .working, statusText: "Working")
        let persona = PersonaFixtures.persona("chief-aptus", mainRowId: "w")
        let candidates = RouteCandidateBuilder.candidates(from: [agent], personas: [persona])
        #expect(candidates.last?.summary == "chief-aptus · worker-2 · Working")
    }

    @Test func noEligibleLiveRowsMeansNoCandidatesAtAll() {
        let candidates = RouteCandidateBuilder.candidates(from: [F.agent("e", section: .ended)])
        #expect(candidates.isEmpty)
    }

    @Test func sessionsAreCappedAtTheTwelveMostRecentlyActiveByFrecency() {
        let agents = (0..<15).map { F.agent("w\($0)", section: .working) }
        let frecency = Dictionary(uniqueKeysWithValues: agents.enumerated().map { offset, agent in
            (agent.id, Self.visited(daysAgo: Double(14 - offset)))
        })
        let candidates = RouteCandidateBuilder.candidates(from: agents, frecency: frecency, now: F.now)
        #expect(candidates.count == 12)
        #expect(candidates.map(\.agentID) == (3..<15).reversed().map { "w\($0)" })
    }

    // MARK: Personas

    @Test func personasBecomeCandidatesAheadOfSessions() {
        let persona = PersonaFixtures.persona(
            "chief-aptus", description: "the AptusFit chief",
            routesWhen: ["AptusFit work"], notFor: ["unrelated projects"]
        )
        let candidates = RouteCandidateBuilder.candidates(from: [], personas: [persona])
        #expect(candidates.map(\.agentID) == ["persona:chief-aptus"])
        #expect(candidates.first?.summary == "chief-aptus — the AptusFit chief. Routes here: AptusFit work. Not for: unrelated projects.")
    }

    @Test func offlinePersonasAreSkipped() {
        let persona = PersonaFixtures.persona("air-notes", offline: true)
        let candidates = RouteCandidateBuilder.candidates(from: [], personas: [persona])
        #expect(candidates.isEmpty)
    }

    @Test func personaNameFromCandidateIDStripsThePrefix() {
        #expect(RouteCandidateBuilder.personaName(fromCandidateID: "persona:chief-aptus") == "chief-aptus")
        #expect(RouteCandidateBuilder.personaName(fromCandidateID: "w1:abc") == nil)
    }

    @Test func emptyPersonasFallsBackToSessionsOnly() {
        let agent = F.agent("w", section: .working)
        let candidates = RouteCandidateBuilder.candidates(from: [agent], personas: [])
        #expect(candidates.map(\.agentID) == ["w"])
    }
}
