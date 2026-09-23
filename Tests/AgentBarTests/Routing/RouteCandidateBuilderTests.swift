import Foundation
import Testing
@testable import AgentBar

struct RouteCandidateBuilderTests {
    typealias F = AgentListFixtures

    @Test func onlyMessageEligibleRowsBecomeLiveCandidates() {
        let working = F.agent("w", label: "worker", section: .working)
        let ended = F.agent("e", section: .ended)
        let blocked = F.agent("b", section: .working)
        var stillBlocked = blocked
        stillBlocked.blocker = .permission
        let notHooked = F.agent("s", section: .working, hasHookData: false)

        let candidates = RouteCandidateBuilder.candidates(from: [working, ended, stillBlocked, notHooked])
        let liveIDs = candidates.map(\.agentID).filter { !$0.hasPrefix(WorkerArea.candidateIDPrefix) }
        #expect(liveIDs == ["w"])
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

    /// The create-new candidates are always offered, even with zero live agents shown — an empty
    /// dashboard is a valid moment to spin up a first worker, so this must not read as "nothing
    /// to route to at all" any more.
    @Test func noEligibleLiveRowsStillOffersTheCreateNewCandidates() {
        let candidates = RouteCandidateBuilder.candidates(from: [F.agent("e", section: .ended)])
        #expect(candidates.map(\.agentID) == WorkerArea.allCases.map(\.candidateID))
    }

    @Test func createNewCandidatesCoverEveryWorkerAreaWithItsOwnIDAndSummary() {
        let candidates = RouteCandidateBuilder.candidates(from: [])
        let createNew = candidates.filter { $0.agentID.hasPrefix(WorkerArea.candidateIDPrefix) }
        #expect(Set(createNew.map(\.agentID)) == Set(WorkerArea.allCases.map(\.candidateID)))
        for area in WorkerArea.allCases {
            #expect(createNew.first { $0.agentID == area.candidateID }?.summary == area.summary)
        }
    }

    @Test func createNewCandidatesAreOfferedAlongsideLiveOnes() {
        let working = F.agent("w", label: "worker", section: .working)
        let candidates = RouteCandidateBuilder.candidates(from: [working])
        #expect(Set(candidates.map(\.agentID)) == Set(["w"] + WorkerArea.allCases.map(\.candidateID)))
    }
}
