import Testing
@testable import AgentBar

struct AgentSelectionTests {
    private let ids = ["a", "b", "c"]

    @Test func downAndUpMoveOneRow() {
        #expect(AgentSelection.moved(from: "a", by: 1, in: ids) == "b")
        #expect(AgentSelection.moved(from: "c", by: -1, in: ids) == "b")
    }

    @Test func wrapsAtBothEnds() {
        #expect(AgentSelection.moved(from: "c", by: 1, in: ids) == "a")
        #expect(AgentSelection.moved(from: "a", by: -1, in: ids) == "c")
    }

    @Test func nothingSelectedDownPicksFirstUpPicksLast() {
        #expect(AgentSelection.moved(from: nil, by: 1, in: ids) == "a")
        #expect(AgentSelection.moved(from: nil, by: -1, in: ids) == "c")
        #expect(AgentSelection.moved(from: "gone", by: 1, in: ids) == "a")
    }

    @Test func emptyListSelectsNothing() {
        #expect(AgentSelection.moved(from: "a", by: 1, in: []) == nil)
        #expect(AgentSelection.reconciled("a", in: []) == nil)
    }

    @Test func reconcileKeepsSurvivorElseFirst() {
        #expect(AgentSelection.reconciled("b", in: ids) == "b")
        #expect(AgentSelection.reconciled("gone", in: ids) == "a")
        #expect(AgentSelection.reconciled(nil, in: ids) == "a")
    }

    @Test func movementSkipsHeadersAndUnfocusableRowsAcrossSections() {
        typealias F = AgentListFixtures
        let snapshot = F.snapshot([
            F.agent("n1", section: .needsYou),
            F.agent("w1", section: .working),
            F.agent("e1", section: .ended)
        ])
        let selectable = F.presentation(snapshot).selectableAgentIDs
        #expect(selectable == ["n1", "w1"])
        #expect(AgentSelection.moved(from: "n1", by: 1, in: selectable) == "w1")
        #expect(AgentSelection.moved(from: "w1", by: 1, in: selectable) == "n1")
    }
}
