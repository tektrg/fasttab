import Foundation
import Testing
import CommandBarKit
@testable import AgentBar

/// The PO's "Nest inside each status section" layout (`AgentListGrouping`, wired in via
/// `AgentListBuilder.rows`, 2026-09-25 — superseding the earlier "one group per project" layout).
/// The four status sections keep their existing order/ranking; inside a section, a worker whose
/// chief is a tree node nests under an anchor row for that chief — the chief's own real row when
/// it is also a member of THIS section, else a dimmed placeholder. Pure — no snapshots, no
/// SwiftUI.
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

    private func rowIDs(agents: [AgentSnapshot], tree: AgentTree) -> [String] {
        AgentListGrouping.rows(for: agents, tree: tree, frecency: [:], now: F.now).map(\.id)
    }

    private func nesting(_ rows: [AgentListRow], id: String) -> AgentRowNesting? {
        guard case .agent(_, let nesting) = rows.first(where: { $0.id == id }) else { return nil }
        return nesting
    }

    private func visited(count: Double) -> FrecencyEntry {
        FrecencyEntry(count: count, lastVisit: F.now, cachedScore: count, cachedScoreAt: F.now)
    }

    // MARK: - A worker whose chief is IN THE SAME section nests under the chief's real row

    @Test func aWorkerInTheSameSectionAsItsChiefNestsUnderTheChiefsRealRow() {
        let tree = AgentTree(generatedAt: nil, chiefs: [chief("c", children: [node("w")])], unassigned: [], parentGone: [])
        let agents = [F.agent("c", section: .working), F.agent("w", section: .working)]
        #expect(rowIDs(agents: agents, tree: tree) == ["section-1", "agent-c", "agent-w"])
    }

    @Test func theChiefsRowIsChiefNestingAndTheWorkersRowIsChildNesting() {
        let tree = AgentTree(generatedAt: nil, chiefs: [chief("c", children: [node("w")])], unassigned: [], parentGone: [])
        let rows = AgentListGrouping.rows(for: [F.agent("c", section: .working), F.agent("w", section: .working)], tree: tree, frecency: [:], now: F.now)
        guard case .chief(let hint, _) = nesting(rows, id: "agent-c") else { Issue.record("expected chief nesting"); return }
        #expect(hint == 0)
        guard case .child = nesting(rows, id: "agent-w") else { Issue.record("expected child nesting"); return }
    }

    // MARK: - A worker whose chief is in a DIFFERENT section (or absent) gets a dimmed placeholder anchor

    @Test func aWorkerWhoseChiefIsInADifferentSectionNestsUnderADimmedPlaceholder() {
        let tree = AgentTree(generatedAt: nil, chiefs: [chief("c", children: [node("w")])], unassigned: [], parentGone: [])
        // Chief "c" isn't shown at all right now (e.g. not currently a live agent) — only its worker is.
        let rows = AgentListGrouping.rows(for: [F.agent("w", section: .working)], tree: tree, frecency: [:], now: F.now)
        #expect(rows.map(\.id) == ["section-1", "chief-placeholder-1-c", "agent-w"])
        guard case .chiefPlaceholder(let node, let section, let hint) = rows[1] else {
            Issue.record("expected a chief placeholder")
            return
        }
        #expect(node.id == "c")
        #expect(section == .working)
        #expect(hint == 0)
        guard case .child = nesting(rows, id: "agent-w") else { Issue.record("expected child nesting"); return }
    }

    @Test func aChiefInADifferentSectionStillGetsItsOwnRealRowThere() {
        let tree = AgentTree(generatedAt: nil, chiefs: [chief("c", children: [node("w")])], unassigned: [], parentGone: [])
        // Chief is blocked (Needs you); its worker is merely Working.
        let agents = [F.agent("c", section: .needsYou), F.agent("w", section: .working)]
        let rows = AgentListGrouping.rows(for: agents, tree: tree, frecency: [:], now: F.now)
        #expect(rows.map(\.id) == ["section-0", "agent-c", "section-1", "chief-placeholder-1-c", "agent-w"])
        guard case .chief = nesting(rows, id: "agent-c") else { Issue.record("expected the chief's real row in Needs you"); return }
    }

    // MARK: - "N needs you" hint is per-chief, not per-anchor: same count wherever it's drawn

    @Test func theNeedsYouHintCountsChildrenInNeedsYouWhateverSectionTheChiefsOwnRowIsIn() {
        let tree = AgentTree(generatedAt: nil, chiefs: [chief("c", children: [node("w1"), node("w2")])], unassigned: [], parentGone: [])
        let agents = [F.agent("c", section: .working), F.agent("w1", section: .needsYou), F.agent("w2", section: .working)]
        let rows = AgentListGrouping.rows(for: agents, tree: tree, frecency: [:], now: F.now)
        guard case .chief(let hint, _) = nesting(rows, id: "agent-c") else { Issue.record("expected chief nesting"); return }
        #expect(hint == 1)   // w1, not w2
        // w1 nests under c's real row IN Needs you too (no more "Needs you dedupe" — every section nests alike).
        #expect(rows.map(\.id) == ["section-0", "chief-placeholder-0-c", "agent-w1", "section-1", "agent-c", "agent-w2"])
    }

    @Test func aPlaceholdersHintMatchesTheSameChiefsRealRowHintElsewhere() {
        let tree = AgentTree(generatedAt: nil, chiefs: [chief("c", children: [node("w1"), node("w2"), node("w3")])], unassigned: [], parentGone: [])
        let agents = [
            F.agent("c", section: .working), F.agent("w1", section: .needsYou),
            F.agent("w2", section: .parked), F.agent("w3", section: .working)
        ]
        let rows = AgentListGrouping.rows(for: agents, tree: tree, frecency: [:], now: F.now)
        guard case .chief(let realHint, _) = nesting(rows, id: "agent-c") else { Issue.record("expected chief nesting"); return }
        guard case .chiefPlaceholder(_, _, let placeholderHint) = rows.first(where: { row in
            if case .chiefPlaceholder(let node, .parked, _) = row { return node.id == "c" }
            return false
        }) else {
            Issue.record("expected a placeholder in Parked")
            return
        }
        #expect(realHint == 1)
        #expect(placeholderHint == 1)
    }

    // MARK: - Group position = the best-ranked member (chief or any child)

    @Test func aGroupsPositionIsPulledUpByItsBestRankedChild() {
        // Needs you ranks blocked-first; both are blocked here, so rely on frecency inside Working
        // instead: w1 has far higher frecency than c or w2, so c's group should lead.
        let tree = AgentTree(generatedAt: nil, chiefs: [
            chief("c", children: [node("w1"), node("w2")])
        ], unassigned: [], parentGone: [])
        let loner = F.agent("loner", section: .working)
        let agents = [loner, F.agent("c", section: .working), F.agent("w1", section: .working), F.agent("w2", section: .working)]
        let frecency: [String: FrecencyEntry] = [
            "w1": visited(count: 100)
        ]
        let rows = AgentListGrouping.rows(for: agents, tree: tree, frecency: frecency, now: F.now)
        // w1's high frecency pulls the whole c-group (c, w1, w2) ahead of the untethered "loner".
        #expect(rows.map(\.id) == ["section-1", "agent-c", "agent-w1", "agent-w2", "agent-loner"])
    }

    @Test func childrenKeepTheSectionsOwnRankingOrderAmongThemselves() {
        let tree = AgentTree(generatedAt: nil, chiefs: [chief("c", children: [node("w1"), node("w2")])], unassigned: [], parentGone: [])
        let agents = [F.agent("c", section: .working), F.agent("w1", section: .working), F.agent("w2", section: .working)]
        let frecency: [String: FrecencyEntry] = ["w2": visited(count: 50)]
        let rows = AgentListGrouping.rows(for: agents, tree: tree, frecency: frecency, now: F.now)
        // w2 outranks w1 by frecency, so it comes first among the children, same as Working's own rule.
        #expect(rows.map(\.id) == ["section-1", "agent-c", "agent-w2", "agent-w1"])
    }

    // MARK: - Parent-gone / untracked agents stay flat (loose), never indented, never hidden

    @Test func aParentGoneWorkerStaysFlatWithItsLostParentLabel() {
        let tree = AgentTree(
            generatedAt: nil, chiefs: [], unassigned: [],
            parentGone: [AgentTree.ParentGoneEntry(node: node("orphan"), lostParentID: "dead-chief", lostParentLabel: "dead-chief-label")]
        )
        let rows = AgentListGrouping.rows(for: [F.agent("orphan", section: .working)], tree: tree, frecency: [:], now: F.now)
        #expect(rows.map(\.id) == ["section-1", "agent-orphan"])
        guard case .loose(let lostParentLabel, _) = nesting(rows, id: "agent-orphan") else {
            Issue.record("expected loose nesting")
            return
        }
        #expect(lostParentLabel == "dead-chief-label")
    }

    @Test func aPlainUnassignedNodeWithNoBadgeIsJustFlat() {
        // Nothing to carry through (no lost-parent label, local machine has no badge) — same as
        // an agent the tree never mentions at all: plain `.flat`, no decorations.
        let tree = AgentTree(generatedAt: nil, chiefs: [], unassigned: [node("loner")], parentGone: [])
        let rows = AgentListGrouping.rows(for: [F.agent("loner", section: .working)], tree: tree, frecency: [:], now: F.now)
        #expect(nesting(rows, id: "agent-loner") == .flat)
    }

    @Test func anUnassignedNodeOnAirStaysLooseSoItsBadgeStillDraws() {
        let tree = AgentTree(generatedAt: nil, chiefs: [], unassigned: [node("loner", machine: "air-m1")], parentGone: [])
        let rows = AgentListGrouping.rows(for: [F.agent("loner", section: .working)], tree: tree, frecency: [:], now: F.now)
        guard case .loose(let lostParentLabel, let machineBadge) = nesting(rows, id: "agent-loner") else {
            Issue.record("expected loose nesting")
            return
        }
        #expect(lostParentLabel == nil)
        #expect(machineBadge == "Air")
    }

    @Test func anAgentTheTreeNeverMentionsStaysPlainFlatNeverHidden() {
        let tree = AgentTree(generatedAt: nil, chiefs: [chief("c", children: [])], unassigned: [], parentGone: [])
        let agents = [F.agent("c", section: .working), F.agent("untracked", section: .working)]
        let rows = AgentListGrouping.rows(for: agents, tree: tree, frecency: [:], now: F.now)
        #expect(Set(rows.map(\.id)) == ["section-1", "agent-c", "agent-untracked"])
        #expect(nesting(rows, id: "agent-untracked") == .flat)
    }

    // MARK: - Cross-project marker / Air badge carried through unedited

    @Test func aCrossProjectChildKeepsItsMarkerInTheNestedRow() {
        let tree = AgentTree(generatedAt: nil, chiefs: [chief("c", children: [node("w", project: "otherProj", crossProject: true)])], unassigned: [], parentGone: [])
        let rows = AgentListGrouping.rows(for: [F.agent("c", section: .working), F.agent("w", section: .working)], tree: tree, frecency: [:], now: F.now)
        guard case .child(let crossProject, _) = nesting(rows, id: "agent-w") else { Issue.record("expected a child nesting"); return }
        #expect(crossProject)
    }

    @Test func anAirMachineChildCarriesTheAirBadge() {
        let tree = AgentTree(generatedAt: nil, chiefs: [chief("c", children: [node("w", machine: "air-m1")])], unassigned: [], parentGone: [])
        let rows = AgentListGrouping.rows(for: [F.agent("c", section: .working), F.agent("w", section: .working)], tree: tree, frecency: [:], now: F.now)
        guard case .child(_, let machineBadge) = nesting(rows, id: "agent-w") else { Issue.record("expected a child nesting"); return }
        #expect(machineBadge == "Air")
    }

    @Test func anAirChiefPlaceholderCarriesTheAirBadge() {
        let airChiefNode = AgentTreeNode(
            id: "c", label: "c", project: "proj", projectRoot: nil, machine: "air-m1", paneId: "w1:c",
            alive: true, status: nil, crossProject: false, isChiefMode: true, children: [node("w")]
        )
        let tree = AgentTree(generatedAt: nil, chiefs: [airChiefNode], unassigned: [], parentGone: [])
        // Force the placeholder path by not showing the chief's own snapshot at all.
        let rows = AgentListGrouping.rows(for: [F.agent("w", section: .working)], tree: tree, frecency: [:], now: F.now)
        guard case .chiefPlaceholder(let node, _, _) = rows.first(where: { $0.id == "chief-placeholder-1-c" }) else {
            Issue.record("expected a placeholder")
            return
        }
        #expect(node.machineBadge == "Air")
    }

    // MARK: - AgentListBuilder.rows: search flattens, empty/missing tree falls back

    @Test func searchingFallsBackToTheFlatStatusSectionsEvenWithATreeLoaded() {
        let tree = AgentTree(generatedAt: nil, chiefs: [chief("c", children: [node("w")])], unassigned: [], parentGone: [])
        let agents = [F.agent("c", section: .working), F.agent("w", section: .working)]
        let rows = AgentListBuilder.rows(for: agents, tree: tree, isSearching: true, frecency: [:], now: F.now)
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

    @Test func aNonSearchingNonEmptyTreeNestsInsteadOfFlattening() {
        let tree = AgentTree(generatedAt: nil, chiefs: [chief("c", children: [])], unassigned: [], parentGone: [])
        let rows = AgentListBuilder.rows(for: [F.agent("c", section: .working)], tree: tree, isSearching: false, frecency: [:], now: F.now)
        #expect(rows.map(\.id) == ["section-1", "agent-c"])
        guard case .chief = nesting(rows, id: "agent-c") else { Issue.record("expected chief nesting"); return }
    }

    @Test func needsYouKeepsItsSectionPositionAheadOfWorkingEtc() {
        let tree = AgentTree(generatedAt: nil, chiefs: [chief("c", children: [])], unassigned: [], parentGone: [])
        let agents = [F.agent("blocked", section: .needsYou), F.agent("c", section: .working)]
        let rows = AgentListBuilder.rows(for: agents, tree: tree, isSearching: false, frecency: [:], now: F.now)
        #expect(rows.map(\.id) == ["section-0", "agent-blocked", "section-1", "agent-c"])
        #expect(nesting(rows, id: "agent-blocked") == .flat)
    }
}
