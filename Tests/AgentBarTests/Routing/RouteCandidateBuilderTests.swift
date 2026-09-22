import Foundation
import Testing
@testable import AgentBar

struct RouteCandidateBuilderTests {
    typealias F = AgentListFixtures

    @Test func onlyMessageEligibleRowsBecomeCandidates() {
        let working = F.agent("w", label: "worker", section: .working)
        let ended = F.agent("e", section: .ended)
        let blocked = F.agent("b", section: .working)
        var stillBlocked = blocked
        stillBlocked.blocker = .permission
        let notHooked = F.agent("s", section: .working, hasHookData: false)

        let candidates = RouteCandidateBuilder.candidates(from: [working, ended, stillBlocked, notHooked])
        #expect(candidates.map(\.agentID) == ["w"])
    }

    @Test func summaryCarriesLabelProjectAndStatus() {
        let agent = F.agent("w", label: "worker-2", project: "AptusFit", section: .working, statusText: "Working")
        let candidates = RouteCandidateBuilder.candidates(from: [agent])
        #expect(candidates.first?.summary == "label: worker-2 · project: AptusFit · status: Working")
    }

    @Test func aMissingProjectIsLeftOutRatherThanShowingAPlaceholder() {
        let agent = F.agent("w", label: "worker-2", project: nil, section: .working, statusText: "Working")
        let candidates = RouteCandidateBuilder.candidates(from: [agent])
        #expect(candidates.first?.summary == "label: worker-2 · status: Working")
    }

    @Test func noEligibleRowsMeansNoCandidates() {
        #expect(RouteCandidateBuilder.candidates(from: [F.agent("e", section: .ended)]).isEmpty)
    }
}
