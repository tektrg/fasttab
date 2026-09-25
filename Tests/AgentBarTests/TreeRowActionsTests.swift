import Foundation
import Testing
@testable import AgentBar

/// "Report to…" / "Stop reporting" — the row ⋯ menu's equivalents of ⌘] / ⌘[
/// (`TreeRowActions`, and their wiring into `AgentPanelModel.press`/`isPressable`/`usableButtons`).
struct TreeRowActionsTests {
    typealias F = AgentListFixtures

    private func node(_ id: String, project: String = "proj") -> AgentTreeNode {
        AgentTreeNode(
            id: id, label: id, project: project, projectRoot: nil, machine: "local", paneId: "w1:\(id)",
            alive: true, status: nil, crossProject: false, isChiefMode: false
        )
    }

    private func chief(_ id: String, project: String = "proj", children: [AgentTreeNode] = []) -> AgentTreeNode {
        AgentTreeNode(
            id: id, label: id, project: project, projectRoot: nil, machine: "local", paneId: "w1:\(id)",
            alive: true, status: nil, crossProject: false, isChiefMode: true, children: children
        )
    }

    // MARK: - menuItems(forAgentID:tree:)

    @Test func aChiefGetsNeitherReportToNorStopReporting() {
        let tree = AgentTree(generatedAt: nil, chiefs: [chief("c")], unassigned: [], parentGone: [])
        #expect(TreeRowActions.menuItems(forAgentID: "c", tree: tree).isEmpty)
    }

    @Test func aWorkerNestedUnderALiveChiefGetsBoth() {
        let tree = AgentTree(generatedAt: nil, chiefs: [chief("c", children: [node("w")])], unassigned: [], parentGone: [])
        #expect(TreeRowActions.menuItems(forAgentID: "w", tree: tree).map(\.button) == [.reportTo, .stopReporting])
    }

    @Test func anUnassignedWorkerGetsOnlyReportTo() {
        let tree = AgentTree(generatedAt: nil, chiefs: [], unassigned: [node("u")], parentGone: [])
        #expect(TreeRowActions.menuItems(forAgentID: "u", tree: tree).map(\.button) == [.reportTo])
    }

    @Test func aParentGoneWorkerGetsOnlyReportToToo() {
        let tree = AgentTree(generatedAt: nil, chiefs: [], unassigned: [], parentGone: [
            AgentTree.ParentGoneEntry(node: node("p"), lostParentID: "dead", lostParentLabel: "dead")
        ])
        #expect(TreeRowActions.menuItems(forAgentID: "p", tree: tree).map(\.button) == [.reportTo])
    }

    @Test func nothingIsOfferedBeforeTheTreeHasLoadedOrForAnUntrackedAgent() {
        #expect(TreeRowActions.menuItems(forAgentID: "anyone", tree: nil).isEmpty)
        let tree = AgentTree(generatedAt: nil, chiefs: [chief("c")], unassigned: [], parentGone: [])
        #expect(TreeRowActions.menuItems(forAgentID: "untracked", tree: tree).isEmpty)
    }

    // MARK: - availableButtons: a .moreActions trigger appears only if the row needed one

    @Test func aPlainWorkingRowWithNoOtherMoreActionsStillGetsATriggerForReportTo() {
        let tree = AgentTree(generatedAt: nil, chiefs: [], unassigned: [node("w")], parentGone: [])
        // RowButtons alone gives Message + moreActions for an eligible working row already, so
        // pick a row RowButtons would NOT already add a trigger for: hasHookData false removes
        // Message eligibility, leaving RowButtons with an empty strip.
        let agent = F.agent("w", section: .working, hasHookData: false)
        #expect(RowButtons.available(for: agent).isEmpty)
        #expect(TreeRowActions.availableButtons(for: agent, tree: tree).map(\.button) == [.moreActions])
    }

    @Test func aRowRowButtonsAlreadyGaveATriggerToIsNotGivenASecondOne() {
        let tree = AgentTree(generatedAt: nil, chiefs: [], unassigned: [node("w")], parentGone: [])
        let agent = F.agent("w", section: .working)   // message-eligible: RowButtons already appends .moreActions
        let buttons = TreeRowActions.availableButtons(for: agent, tree: tree).map(\.button)
        #expect(buttons.filter { $0 == .moreActions }.count == 1)
    }

    @Test func aChiefRowNeverGetsAMoreActionsTriggerFromTreeItemsAlone() {
        let tree = AgentTree(generatedAt: nil, chiefs: [chief("c")], unassigned: [], parentGone: [])
        let agent = F.agent("c", section: .working, hasHookData: false)
        #expect(TreeRowActions.availableButtons(for: agent, tree: tree).isEmpty)
    }

    // MARK: - isPressable

    @Test func reportToIsPressableOnlyWhenTheMenuOffersIt() {
        let tree = AgentTree(generatedAt: nil, chiefs: [chief("c", children: [node("w")])], unassigned: [], parentGone: [])
        let agent = F.agent("w", section: .working)
        let chiefAgent = F.agent("c", section: .working)
        #expect(TreeRowActions.isPressable(.reportTo, on: agent, tree: tree))
        #expect(TreeRowActions.isPressable(.stopReporting, on: agent, tree: tree))
        #expect(!TreeRowActions.isPressable(.reportTo, on: chiefAgent, tree: tree))   // chiefs get neither
        #expect(!TreeRowActions.isPressable(.stopReporting, on: chiefAgent, tree: tree))
    }

    @Test func ordinaryButtonsStillDelegateToRowButtons() {
        let agent = F.agent("a", section: .needsYou)
        #expect(TreeRowActions.isPressable(.park, on: agent, tree: nil) == RowButtons.isPressable(.park, on: agent))
        #expect(TreeRowActions.isPressable(.done, on: agent, tree: nil) == RowButtons.isPressable(.done, on: agent))
    }

    // MARK: - allMenuItems: RowButtons' items plus the tree ones, in that order

    @Test func allMenuItemsPutsReportToAndStopReportingAfterTheOrdinaryMenuItems() {
        let tree = AgentTree(generatedAt: nil, chiefs: [chief("c", children: [node("w")])], unassigned: [], parentGone: [])
        let agent = F.agent("w", section: .working)   // message-eligible: RowButtons offers Compact/Clear
        #expect(TreeRowActions.allMenuItems(for: agent, tree: tree).map(\.button) == [.compact, .clear, .reportTo, .stopReporting])
    }
}

/// `AgentPanelModel.press(.reportToNearestChief / .stopReporting)`: the row-menu path onto the
/// same optimistic attach/detach `AgentTreeModel` already gives ⌘]/⌘[, exercised through a real
/// (fake-backed) `AgentTreeModel` so both the immediate optimistic move and the eventual dashboard
/// call are checked — not just the pure `TreeRowActions` gating above.
@MainActor
struct TreeRowActionsPanelModelTests {
    typealias F = AgentListFixtures

    private func node(_ id: String, project: String = "proj") -> AgentTreeNode {
        AgentTreeNode(
            id: id, label: id, project: project, projectRoot: nil, machine: "local", paneId: "w1:\(id)",
            alive: true, status: nil, crossProject: false, isChiefMode: false
        )
    }

    private func chief(_ id: String, project: String = "proj", children: [AgentTreeNode] = []) -> AgentTreeNode {
        AgentTreeNode(
            id: id, label: id, project: project, projectRoot: nil, machine: "local", paneId: "w1:\(id)",
            alive: true, status: nil, crossProject: false, isChiefMode: true, children: children
        )
    }

    private func treeSnapshot(_ tree: AgentTree, agents: [AgentSnapshot]) -> StatusSnapshot {
        StatusSnapshot(agents: agents, health: .ok, fetchedAt: F.now, boardIsCurrent: true, agentTree: tree)
    }

    private func makeModel(editing: AgentTreeFakeEditing) -> AgentPanelModel {
        AgentPanelModel(
            store: FrecencyStore(defaults: makeScratchDefaults("tree-row-actions")),
            triageStore: TriageStore(defaults: makeScratchDefaults("tree-row-actions-triage")),
            treeModel: AgentTreeModel(editing: editing),
            now: { F.now }
        )
    }

    @Test func pressingReportToAttachesToTheNearestChiefAboveTheRowInDisplayOrder() async {
        let editing = AgentTreeFakeEditing()
        let model = makeModel(editing: editing)
        let tree = AgentTree(generatedAt: nil, chiefs: [chief("c1"), chief("c2")], unassigned: [node("w1")], parentGone: [])
        model.receive(treeSnapshot(tree, agents: [F.agent("c1", section: .working), F.agent("c2", section: .working), F.agent("w1", section: .working)]))

        model.press(.reportTo, on: "w1")

        #expect(model.treeModel.tree?.chiefs.first { $0.id == "c2" }?.children.map(\.id) == ["w1"])   // optimistic, immediate
        await waitUntil { !editing.attachCalls.isEmpty }
        #expect(editing.attachCalls == [.init(child: "w1", parent: "c2", confirmCrossProject: false)])
    }

    @Test func pressingStopReportingDetachesAWorkerToUnassigned() async {
        let editing = AgentTreeFakeEditing()
        let model = makeModel(editing: editing)
        let tree = AgentTree(generatedAt: nil, chiefs: [chief("c", children: [node("w")])], unassigned: [], parentGone: [])
        model.receive(treeSnapshot(tree, agents: [F.agent("c", section: .working), F.agent("w", section: .working)]))

        model.press(.stopReporting, on: "w")

        #expect(model.treeModel.tree?.unassigned.map(\.id) == ["w"])
        #expect(model.treeModel.tree?.chiefs.first?.children.isEmpty == true)
        await waitUntil { !editing.detachCalls.isEmpty }
        #expect(editing.detachCalls == ["w"])
    }

    @Test func reportToOnAChiefRowIsRefusedNoOptimisticMoveNoNetworkCall() async {
        let editing = AgentTreeFakeEditing()
        let model = makeModel(editing: editing)
        let tree = AgentTree(generatedAt: nil, chiefs: [chief("c1"), chief("c2")], unassigned: [], parentGone: [])
        model.receive(treeSnapshot(tree, agents: [F.agent("c1", section: .working), F.agent("c2", section: .working)]))

        // Not pressable at all: TreeRowActions.menuItems never offers a chief either action, so
        // AgentPanelModel.press's isPressable gate refuses it before touching the tree.
        model.press(.reportTo, on: "c1")

        await settleTasks()
        #expect(editing.attachCalls.isEmpty)
        #expect(model.treeModel.tree == tree)
    }

    @Test func stopReportingOnAnAlreadyUnassignedRowIsRefusedNoNetworkCall() async {
        let editing = AgentTreeFakeEditing()
        let model = makeModel(editing: editing)
        let tree = AgentTree(generatedAt: nil, chiefs: [], unassigned: [node("u")], parentGone: [])
        model.receive(treeSnapshot(tree, agents: [F.agent("u", section: .working)]))

        model.press(.stopReporting, on: "u")

        await settleTasks()
        #expect(editing.detachCalls.isEmpty)
    }

    @Test func aMenuPressWorksEvenWhenThatRowIsNotTheCurrentSelection() async {
        let editing = AgentTreeFakeEditing()
        let model = makeModel(editing: editing)
        let tree = AgentTree(generatedAt: nil, chiefs: [chief("c")], unassigned: [node("w1"), node("w2")], parentGone: [])
        model.receive(treeSnapshot(tree, agents: [F.agent("c", section: .working), F.agent("w1", section: .working), F.agent("w2", section: .working)]))
        model.select(agentID: "w1")

        model.press(.reportTo, on: "w2")   // a ⋯ menu click on a row that isn't selected

        #expect(model.treeModel.tree?.chiefs.first?.children.map(\.id) == ["w2"])
        await waitUntil { !editing.attachCalls.isEmpty }
        #expect(editing.attachCalls == [.init(child: "w2", parent: "c", confirmCrossProject: false)])
    }
}
