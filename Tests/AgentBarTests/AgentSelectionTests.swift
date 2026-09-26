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

    /// A dimmed chief placeholder anchor (`AgentListRow.chiefPlaceholder`, `AgentListGrouping`) has
    /// no real agent behind it — nothing to focus or press — so keyboard selection must skip
    /// straight over it, same as it already skips headers. This is the "skip" choice from the two
    /// the PO offered (skip the placeholder, or jump to the chief's real row elsewhere): the real
    /// row may not even be in `selectable` right now (a different section, possibly filtered out),
    /// so `AgentSelection` — which only ever walks a flat list of currently-selectable agent ids
    /// and has no notion of "the same chief elsewhere" — has nothing sound to jump to; skipping
    /// needs no new concept at all.
    @Test func movementSkipsAChiefPlaceholderWithNoRealAgentToJumpTo() {
        typealias F = AgentListFixtures
        let chiefNode = AgentTreeNode(
            id: "chief", label: "chief", project: "proj", projectRoot: nil, machine: "local", paneId: "w1:chief",
            alive: true, status: nil, crossProject: false, isChiefMode: true,
            children: [AgentTreeNode(
                id: "w1", label: "w1", project: "proj", projectRoot: nil, machine: "local", paneId: "w1:w1",
                alive: true, status: nil, crossProject: false, isChiefMode: false
            )]
        )
        let tree = AgentTree(generatedAt: nil, chiefs: [chiefNode], unassigned: [], parentGone: [])
        // "chief" itself isn't shown right now — only its worker "w1" is, so its group gets a
        // placeholder anchor instead of "chief"'s real row.
        let snapshot = F.snapshot([F.agent("w1", section: .working)], agentTree: tree)
        let presentation = F.presentation(snapshot)
        #expect(presentation.rows.contains { row in
            if case .chiefPlaceholder = row { return true }
            return false
        })
        #expect(presentation.selectableAgentIDs == ["w1"])
    }

    @Test func neighbourIsTheNextRowElseThePreviousElseNothing() {
        #expect(AgentSelection.neighbour(of: "a", in: ["a", "b", "c"]) == "b")
        #expect(AgentSelection.neighbour(of: "c", in: ["a", "b", "c"]) == "b")
        #expect(AgentSelection.neighbour(of: "a", in: ["a"]) == nil)
        #expect(AgentSelection.neighbour(of: "x", in: ["a", "b"]) == nil)
    }
}
