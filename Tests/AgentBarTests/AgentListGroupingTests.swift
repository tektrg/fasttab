import Foundation
import Testing
@testable import AgentBar

/// The PO's "Nest under chief" layout (`AgentListGrouping`, wired in via `AgentListBuilder.rows`):
/// Needs you flat on top (built by the caller, not this file's concern), one group per chief's
/// project with its workers indented beneath it, then a trailing Unassigned group for parent-gone
/// and untracked rows. Pure — no snapshots, no SwiftUI.
@MainActor
struct AgentListGroupingTests {
    typealias F = AgentListFixtures

    private func node(_ id: String, project: String = "proj", machine: String = "local", crossProject: Bool = false) -> AgentTreeNode {
        AgentTreeNode(
            id: id, label: id, project: project, projectRoot: nil, machine: machine, paneId: "w1:\(id)",
            alive: true, status: nil, crossProject: crossProject, isChiefMode: false
        )
    }

    private func chief(_ id: String, project: String = "proj", children: [AgentTreeNode] = []) -> AgentTreeNode {
        AgentTreeNode(
            id: id, label: id, project: project, projectRoot: nil, machine: "local", paneId: "w1:\(id)",
            alive: true, status: nil, crossProject: false, isChiefMode: true, children: children
        )
    }

    /// Row ids as `AgentListBuilder.rows` would hand the view: groups + nested agents, no search,
    /// a non-empty tree.
    private func rowIDs(agents: [AgentSnapshot], tree: AgentTree, needsYouIDs: Set<String> = []) -> [String] {
        AgentListGrouping.rows(for: agents, tree: tree, needsYouIDs: needsYouIDs, frecency: [:], now: F.now).map(\.id)
    }

    // MARK: - Needs you dedupe

    @Test func aWorkerAlreadyInNeedsYouIsSkippedInItsChiefsGroupEntirely() {
        let tree = AgentTree(generatedAt: nil, chiefs: [chief("c", children: [node("blocked"), node("ok")])], unassigned: [], parentGone: [])
        let agents = [F.agent("c", section: .working), F.agent("ok", section: .working)]   // "blocked" not even shown (it's the Needs you caller's job)
        let rows = AgentListGrouping.rows(for: agents, tree: tree, needsYouIDs: ["blocked"], frecency: [:], now: F.now)
        #expect(rows.map(\.id) == ["group-project-proj", "agent-c", "agent-ok"])
    }

    @Test func aChiefBlockedOnYouIsShownOnlyInNeedsYouButItsGroupKeepsItsChildren() {
        let tree = AgentTree(generatedAt: nil, chiefs: [chief("c", children: [node("worker")])], unassigned: [], parentGone: [])
        let agents = [F.agent("worker", section: .working)]   // "c" itself excluded (Needs you already has it)
        let rows = AgentListGrouping.rows(for: agents, tree: tree, needsYouIDs: ["c"], frecency: [:], now: F.now)
        // No chief row here, but the group header and its worker still appear.
        #expect(rows.map(\.id) == ["group-project-proj", "agent-worker"])
    }

    @Test func aChiefsNeedsYouHintCountsOnlyItsOwnBlockedChildren() {
        let tree = AgentTree(generatedAt: nil, chiefs: [
            chief("c1", children: [node("w1"), node("w2")]),
            chief("c2", project: "other", children: [node("w3")])
        ], unassigned: [], parentGone: [])
        let agents = [F.agent("c1", section: .working), F.agent("c2", project: "other", section: .working), F.agent("w2", section: .working)]
        let rows = AgentListGrouping.rows(for: agents, tree: tree, needsYouIDs: ["w1"], frecency: [:], now: F.now)
        guard case .agent(_, let nesting) = rows.first(where: { $0.id == "agent-c1" }) else {
            Issue.record("expected c1's row")
            return
        }
        guard case .chief(let hint, _) = nesting else {
            Issue.record("expected a chief nesting")
            return
        }
        #expect(hint == 1)   // only w1, not w2
    }

    // MARK: - Two chiefs in different projects

    @Test func twoChiefsInDifferentProjectsGetTheirOwnGroupsInFirstSeenOrder() {
        let tree = AgentTree(generatedAt: nil, chiefs: [
            chief("c-aptus", project: "AptusFit", children: [node("worker-a", project: "AptusFit")]),
            chief("c-cmdbar", project: "command-bar-macos", children: [node("worker-b", project: "command-bar-macos")])
        ], unassigned: [], parentGone: [])
        let agents = [
            F.agent("c-aptus", project: "AptusFit", section: .working),
            F.agent("worker-a", project: "AptusFit", section: .working),
            F.agent("c-cmdbar", project: "command-bar-macos", section: .working),
            F.agent("worker-b", project: "command-bar-macos", section: .working)
        ]
        #expect(rowIDs(agents: agents, tree: tree) == [
            "group-project-AptusFit", "agent-c-aptus", "agent-worker-a",
            "group-project-command-bar-macos", "agent-c-cmdbar", "agent-worker-b"
        ])
    }

    @Test func aSecondChiefForAnAlreadySeenProjectJoinsTheSameGroupRightAfterTheFirst() {
        let tree = AgentTree(generatedAt: nil, chiefs: [
            chief("c1", project: "proj", children: [node("w1")]),
            chief("c2", project: "proj", children: [node("w2")])
        ], unassigned: [], parentGone: [])
        let agents = [F.agent("c1", section: .working), F.agent("w1", section: .working), F.agent("c2", section: .working), F.agent("w2", section: .working)]
        #expect(rowIDs(agents: agents, tree: tree) == [
            "group-project-proj", "agent-c1", "agent-w1", "agent-c2", "agent-w2"
        ])
    }

    // MARK: - Parent-gone placement

    @Test func aParentGoneWorkerLandsInUnassignedWithItsLostParentLabel() {
        let tree = AgentTree(
            generatedAt: nil, chiefs: [], unassigned: [],
            parentGone: [AgentTree.ParentGoneEntry(node: node("orphan"), lostParentID: "dead-chief", lostParentLabel: "dead-chief-label")]
        )
        let agents = [F.agent("orphan", section: .working)]
        let rows = AgentListGrouping.rows(for: agents, tree: tree, needsYouIDs: [], frecency: [:], now: F.now)
        #expect(rows.map(\.id) == ["group-unassigned", "agent-orphan"])
        guard case .agent(_, let nesting) = rows.last else {
            Issue.record("expected the orphan row")
            return
        }
        guard case .unassigned(let lostParentLabel, _) = nesting else {
            Issue.record("expected an unassigned nesting")
            return
        }
        #expect(lostParentLabel == "dead-chief-label")
    }

    @Test func plainUnassignedRowsCarryNoLostParentLabel() {
        let tree = AgentTree(generatedAt: nil, chiefs: [], unassigned: [node("loner")], parentGone: [])
        let rows = AgentListGrouping.rows(for: [F.agent("loner", section: .working)], tree: tree, needsYouIDs: [], frecency: [:], now: F.now)
        guard case .agent(_, let nesting) = rows.last, case .unassigned(let lostParentLabel, _) = nesting else {
            Issue.record("expected an unassigned nesting")
            return
        }
        #expect(lostParentLabel == nil)
    }

    @Test func anAgentTheTreeNeverMentionsStillEndsUpInUnassignedNeverHidden() {
        let tree = AgentTree(generatedAt: nil, chiefs: [chief("c", children: [])], unassigned: [], parentGone: [])
        let agents = [F.agent("c", section: .working), F.agent("untracked", section: .working)]
        #expect(rowIDs(agents: agents, tree: tree) == ["group-project-proj", "agent-c", "group-unassigned", "agent-untracked"])
    }

    @Test func needsYouParentGoneAndUnassignedRowsAreSkippedFromUnassignedToo() {
        let tree = AgentTree(
            generatedAt: nil, chiefs: [], unassigned: [node("u1")],
            parentGone: [AgentTree.ParentGoneEntry(node: node("p1"), lostParentID: "x", lostParentLabel: "x")]
        )
        let agents = [F.agent("u1", section: .working)]   // p1 not even in `agents` (Needs you owns it)
        let rows = AgentListGrouping.rows(for: agents, tree: tree, needsYouIDs: ["p1"], frecency: [:], now: F.now)
        #expect(rows.map(\.id) == ["group-unassigned", "agent-u1"])
    }

    // MARK: - Cross-project marker carried through

    @Test func aCrossProjectChildKeepsItsMarkerInTheNestedRow() {
        let tree = AgentTree(generatedAt: nil, chiefs: [chief("c", children: [node("w", project: "otherProj", crossProject: true)])], unassigned: [], parentGone: [])
        let rows = AgentListGrouping.rows(for: [F.agent("c", section: .working), F.agent("w", section: .working)], tree: tree, needsYouIDs: [], frecency: [:], now: F.now)
        guard case .agent(_, let nesting) = rows.last, case .child(let crossProject, _) = nesting else {
            Issue.record("expected a child nesting")
            return
        }
        #expect(crossProject)
    }

    @Test func anAirMachineChildCarriesTheAirBadge() {
        let tree = AgentTree(generatedAt: nil, chiefs: [chief("c", children: [node("w", machine: "air-m1")])], unassigned: [], parentGone: [])
        let rows = AgentListGrouping.rows(for: [F.agent("c", section: .working), F.agent("w", section: .working)], tree: tree, needsYouIDs: [], frecency: [:], now: F.now)
        guard case .agent(_, let nesting) = rows.last, case .child(_, let machineBadge) = nesting else {
            Issue.record("expected a child nesting")
            return
        }
        #expect(machineBadge == "Air")
    }

    // MARK: - AgentListBuilder.rows: search flattens, empty/missing tree falls back

    @Test func searchingFallsBackToTheFlatStatusSectionsEvenWithATreeLoaded() {
        let tree = AgentTree(generatedAt: nil, chiefs: [chief("c", children: [node("w")])], unassigned: [], parentGone: [])
        let agents = [F.agent("c", section: .working), F.agent("w", section: .working)]
        let rows = AgentListBuilder.rows(for: agents, tree: tree, isSearching: true, frecency: [:], now: F.now)
        // Flat: a section header, no group headers, nesting is `.flat` throughout.
        #expect(rows.map(\.id) == ["section-1", "agent-c", "agent-w"])
        #expect(rows.allSatisfy { row in
            guard case .agent(_, let nesting) = row else { return true }
            return nesting == .flat
        })
    }

    @Test func aNilTreeFallsBackToFlatSections() {
        let rows = AgentListBuilder.rows(for: [F.agent("a", section: .working)], tree: nil, isSearching: false, frecency: [:], now: F.now)
        #expect(rows.map(\.id) == ["section-1", "agent-a"])
    }

    @Test func anEmptyTreeFallsBackToFlatSectionsToo() {
        let rows = AgentListBuilder.rows(for: [F.agent("a", section: .working)], tree: .empty, isSearching: false, frecency: [:], now: F.now)
        #expect(rows.map(\.id) == ["section-1", "agent-a"])
    }

    @Test func aNonSearchingNonEmptyTreeGroupsInsteadOfFlattening() {
        let tree = AgentTree(generatedAt: nil, chiefs: [chief("c", children: [])], unassigned: [], parentGone: [])
        let rows = AgentListBuilder.rows(for: [F.agent("c", section: .working)], tree: tree, isSearching: false, frecency: [:], now: F.now)
        #expect(rows.map(\.id) == ["group-project-proj", "agent-c"])
    }

    @Test func needsYouStaysFlatAndOnTopAheadOfTheGroups() {
        let tree = AgentTree(generatedAt: nil, chiefs: [chief("c", children: [])], unassigned: [], parentGone: [])
        let agents = [F.agent("blocked", section: .needsYou), F.agent("c", section: .working)]
        let rows = AgentListBuilder.rows(for: agents, tree: tree, isSearching: false, frecency: [:], now: F.now)
        #expect(rows.map(\.id) == ["section-0", "agent-blocked", "group-project-proj", "agent-c"])
        guard case .agent(_, let needsYouNesting) = rows[1] else {
            Issue.record("expected the needs-you row")
            return
        }
        #expect(needsYouNesting == .flat)
    }
}
