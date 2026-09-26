import Foundation
import Testing
@testable import AgentBar

@MainActor
struct AgentTreeModelTests {
    private func node(_ id: String, project: String = "proj", machine: String = "local", crossProject: Bool = false) -> AgentTreeNode {
        AgentTreeNode(
            id: id, label: id, project: project, projectRoot: nil, machine: machine, paneId: "w1:\(id)",
            alive: true, status: nil, crossProject: crossProject, isChiefMode: false
        )
    }

    private func chief(_ id: String, project: String = "proj", alive: Bool = true, isChiefMode: Bool = true, children: [AgentTreeNode] = []) -> AgentTreeNode {
        AgentTreeNode(
            id: id, label: id, project: project, projectRoot: nil, machine: "local", paneId: "w1:\(id)",
            alive: alive, status: nil, crossProject: false, isChiefMode: isChiefMode, children: children
        )
    }

    private func snapshot(_ tree: AgentTree?, health: StatusFeedHealth = .ok) -> StatusSnapshot {
        StatusSnapshot(agents: [], health: health, fetchedAt: Date(), boardIsCurrent: true, agentTree: tree)
    }

    // MARK: - Receiving snapshots

    @Test func aHealthySnapshotWithATreePublishesIt() {
        let model = AgentTreeModel()
        let tree = AgentTree(generatedAt: nil, chiefs: [chief("c1")], unassigned: [], parentGone: [])
        model.receive(snapshot(tree))
        #expect(model.tree?.chiefs.map(\.id) == ["c1"])
        #expect(model.featureUnavailable == false)
    }

    @Test func aHealthySnapshotWithNoTreeFieldMeansFeatureUnavailable() {
        let model = AgentTreeModel()
        model.receive(snapshot(nil))
        #expect(model.featureUnavailable == true)
        #expect(model.tree == nil)
    }

    @Test func aDownSnapshotKeepsTheLastKnownTreeAndFlagsUnreachable() {
        let model = AgentTreeModel()
        let tree = AgentTree(generatedAt: nil, chiefs: [chief("c1")], unassigned: [], parentGone: [])
        model.receive(snapshot(tree))
        model.receive(snapshot(nil, health: .down(reason: "down")))
        #expect(model.isDashboardReachable == false)
        #expect(model.tree?.chiefs.map(\.id) == ["c1"])   // not wiped by the blip
    }

    @Test func selectionIsClearedWhenItsNodeDisappearsFromTheNewTree() {
        let model = AgentTreeModel()
        model.receive(snapshot(AgentTree(generatedAt: nil, chiefs: [], unassigned: [node("w1")], parentGone: [])))
        model.selectedNodeID = "w1"
        model.receive(snapshot(AgentTree(generatedAt: nil, chiefs: [], unassigned: [], parentGone: [])))
        #expect(model.selectedNodeID == nil)
    }

    // MARK: - Indent (⌘])

    @Test func indentAttachesToTheNearestChiefAbove() async {
        let editing = AgentTreeFakeEditing()
        let model = AgentTreeModel(editing: editing)
        model.receive(snapshot(AgentTree(generatedAt: nil, chiefs: [chief("c1"), chief("c2")], unassigned: [node("w1")], parentGone: [])))
        model.selectedNodeID = "w1"
        model.indentSelected()
        #expect(model.tree?.chiefs.first { $0.id == "c2" }?.children.map(\.id) == ["w1"])   // optimistic, immediate
        await waitUntil { !editing.attachCalls.isEmpty }
        #expect(editing.attachCalls == [.init(child: "w1", parent: "c2", confirmCrossProject: false)])
    }

    @Test func indentingAChiefIsRefusedClientSideWithNoNetworkCall() async {
        let editing = AgentTreeFakeEditing()
        let model = AgentTreeModel(editing: editing)
        model.receive(snapshot(AgentTree(generatedAt: nil, chiefs: [chief("c1"), chief("c2")], unassigned: [], parentGone: [])))
        model.selectedNodeID = "c2"
        model.indentSelected()
        await settleTasks()
        #expect(editing.attachCalls.isEmpty)
        #expect(model.errorMessage?.contains("two levels only") == true)
    }

    @Test func indentingAWorkerWithNoChiefAboveItInItsOwnSectionShowsAMessageAndCallsNothing() async {
        // Unassigned, not Parent-gone: Parent-gone has its own rules (below), this covers the plain
        // "nothing above it" case the display-order helper still refuses (e.g. the very first row).
        let editing = AgentTreeFakeEditing()
        let model = AgentTreeModel(editing: editing)
        model.receive(snapshot(AgentTree(generatedAt: nil, chiefs: [], unassigned: [node("w1")], parentGone: [])))
        model.selectedNodeID = "w1"
        model.indentSelected()
        await settleTasks()
        #expect(editing.attachCalls.isEmpty)
        #expect(model.errorMessage != nil)
    }

    // MARK: - Indent from Parent-gone (⌘] has nothing "above" it there — QA-flagged gap, fixed)

    @Test func indentingAParentGoneRowWithOneSameProjectLiveChiefAttachesDirectly() async {
        let editing = AgentTreeFakeEditing()
        let model = AgentTreeModel(editing: editing)
        let gone = AgentTree.ParentGoneEntry(node: node("g1", project: "aptusfit"), lostParentID: "dead", lostParentLabel: "Dead Chief")
        model.receive(snapshot(AgentTree(generatedAt: nil, chiefs: [chief("c1", project: "aptusfit")], unassigned: [], parentGone: [gone])))
        model.selectedNodeID = "g1"
        model.indentSelected()
        #expect(model.tree?.chiefs.first?.children.map(\.id) == ["g1"])   // optimistic, immediate
        #expect(model.pendingChiefPicker == nil)
        await waitUntil { !editing.attachCalls.isEmpty }
        #expect(editing.attachCalls == [.init(child: "g1", parent: "c1", confirmCrossProject: false)])
    }

    @Test func indentingAParentGoneRowIgnoresDeadChiefsInTheSameProject() async {
        let editing = AgentTreeFakeEditing()
        let model = AgentTreeModel(editing: editing)
        let gone = AgentTree.ParentGoneEntry(node: node("g1", project: "aptusfit"), lostParentID: "dead", lostParentLabel: "Dead Chief")
        model.receive(snapshot(AgentTree(generatedAt: nil, chiefs: [chief("c1", project: "aptusfit", alive: false)], unassigned: [], parentGone: [gone])))
        model.selectedNodeID = "g1"
        model.indentSelected()
        await settleTasks()
        #expect(editing.attachCalls.isEmpty)
        #expect(model.pendingChiefPicker == nil)
        #expect(model.errorMessage?.contains("No live chief") == true)
    }

    @Test func indentingAParentGoneRowWithNoLiveChiefsAtAllShowsAMessage() async {
        let editing = AgentTreeFakeEditing()
        let model = AgentTreeModel(editing: editing)
        let gone = AgentTree.ParentGoneEntry(node: node("g1"), lostParentID: "dead", lostParentLabel: "Dead Chief")
        model.receive(snapshot(AgentTree(generatedAt: nil, chiefs: [], unassigned: [], parentGone: [gone])))
        model.selectedNodeID = "g1"
        model.indentSelected()
        await settleTasks()
        #expect(editing.attachCalls.isEmpty)
        #expect(model.errorMessage != nil)
    }

    @Test func indentingAParentGoneRowWithTwoSameProjectChiefsOpensAPickerSameProjectFirst() async {
        let editing = AgentTreeFakeEditing()
        let model = AgentTreeModel(editing: editing)
        let gone = AgentTree.ParentGoneEntry(node: node("g1", project: "aptusfit"), lostParentID: "dead", lostParentLabel: "Dead Chief")
        let other = chief("c-other", project: "speechtodo")
        let same1 = chief("c-same1", project: "aptusfit")
        let same2 = chief("c-same2", project: "aptusfit")
        model.receive(snapshot(AgentTree(generatedAt: nil, chiefs: [other, same1, same2], unassigned: [], parentGone: [gone])))
        model.selectedNodeID = "g1"
        model.indentSelected()
        await settleTasks()
        #expect(editing.attachCalls.isEmpty)   // nothing chosen yet
        #expect(model.pendingChiefPicker?.child.id == "g1")
        #expect(model.pendingChiefPicker?.candidates.map(\.id) == ["c-same1", "c-same2", "c-other"])
    }

    @Test func indentingAParentGoneRowPrefersTheSoleChiefModeCandidateAmongSameProjectTies() async {
        let editing = AgentTreeFakeEditing()
        let model = AgentTreeModel(editing: editing)
        let gone = AgentTree.ParentGoneEntry(node: node("g1", project: "aptusfit"), lostParentID: "dead", lostParentLabel: "Dead Chief")
        let notActuallyChiefMode = chief("c-stale", project: "aptusfit", isChiefMode: false)
        let realChief = chief("c-real", project: "aptusfit", isChiefMode: true)
        model.receive(snapshot(AgentTree(generatedAt: nil, chiefs: [notActuallyChiefMode, realChief], unassigned: [], parentGone: [gone])))
        model.selectedNodeID = "g1"
        model.indentSelected()
        #expect(model.pendingChiefPicker == nil)
        await waitUntil { !editing.attachCalls.isEmpty }
        #expect(editing.attachCalls == [.init(child: "g1", parent: "c-real", confirmCrossProject: false)])
    }

    @Test func indentingAParentGoneRowWithNoSameProjectChiefOpensAPickerOfOtherProjects() async {
        let editing = AgentTreeFakeEditing()
        let model = AgentTreeModel(editing: editing)
        let gone = AgentTree.ParentGoneEntry(node: node("g1", project: "aptusfit"), lostParentID: "dead", lostParentLabel: "Dead Chief")
        let other = chief("c-other", project: "speechtodo")
        model.receive(snapshot(AgentTree(generatedAt: nil, chiefs: [other], unassigned: [], parentGone: [gone])))
        model.selectedNodeID = "g1"
        model.indentSelected()
        await settleTasks()
        #expect(model.pendingChiefPicker?.candidates.map(\.id) == ["c-other"])
    }

    @Test func choosingAChiefFromThePickerAttachesAndClosesIt() async throws {
        let editing = AgentTreeFakeEditing()
        let model = AgentTreeModel(editing: editing)
        let gone = AgentTree.ParentGoneEntry(node: node("g1", project: "aptusfit"), lostParentID: "dead", lostParentLabel: "Dead Chief")
        let same1 = chief("c-same1", project: "aptusfit")
        let same2 = chief("c-same2", project: "aptusfit")
        model.receive(snapshot(AgentTree(generatedAt: nil, chiefs: [same1, same2], unassigned: [], parentGone: [gone])))
        model.selectedNodeID = "g1"
        model.indentSelected()
        let picked = try #require(model.pendingChiefPicker?.candidates.first)
        model.chooseChiefForPendingIndent(picked)
        #expect(model.pendingChiefPicker == nil)
        #expect(model.tree?.chiefs.first { $0.id == picked.id }?.children.map(\.id) == ["g1"])
        await waitUntil { !editing.attachCalls.isEmpty }
        #expect(editing.attachCalls == [.init(child: "g1", parent: picked.id, confirmCrossProject: false)])
    }

    @Test func cancelingTheChiefPickerLeavesTheTreeUntouched() async {
        let editing = AgentTreeFakeEditing()
        let model = AgentTreeModel(editing: editing)
        let gone = AgentTree.ParentGoneEntry(node: node("g1", project: "aptusfit"), lostParentID: "dead", lostParentLabel: "Dead Chief")
        let same1 = chief("c-same1", project: "aptusfit")
        let same2 = chief("c-same2", project: "aptusfit")
        model.receive(snapshot(AgentTree(generatedAt: nil, chiefs: [same1, same2], unassigned: [], parentGone: [gone])))
        model.selectedNodeID = "g1"
        model.indentSelected()
        model.cancelChiefPicker()
        #expect(model.pendingChiefPicker == nil)
        await settleTasks()
        #expect(editing.attachCalls.isEmpty)
        #expect(model.tree?.parentGone.map(\.node.id) == ["g1"])   // still there, untouched
    }

    // MARK: - Outdent / detach (⌘[ / ⌘⌫)

    @Test func outdentMovesAChildToUnassignedOptimisticallyThenCallsDetach() async {
        let editing = AgentTreeFakeEditing()
        let model = AgentTreeModel(editing: editing)
        model.receive(snapshot(AgentTree(generatedAt: nil, chiefs: [chief("c1", children: [node("w1")])], unassigned: [], parentGone: [])))
        model.selectedNodeID = "w1"
        model.outdentSelected()
        #expect(model.tree?.unassigned.map(\.id) == ["w1"])
        #expect(model.tree?.chiefs.first?.children.isEmpty == true)
        await waitUntil { !editing.detachCalls.isEmpty }
        #expect(editing.detachCalls == ["w1"])
    }

    @Test func outdentingAChiefIsANoOp() async {
        let editing = AgentTreeFakeEditing()
        let model = AgentTreeModel(editing: editing)
        model.receive(snapshot(AgentTree(generatedAt: nil, chiefs: [chief("c1")], unassigned: [], parentGone: [])))
        model.selectedNodeID = "c1"
        model.outdentSelected()
        await settleTasks()
        #expect(editing.detachCalls.isEmpty)
    }

    // MARK: - Cross-project confirm (409)

    @Test func needsConfirmRevertsTheOptimisticMoveAndOpensAConfirmation() async {
        let editing = AgentTreeFakeEditing()
        editing.attachReply = .needsConfirm(message: "Different projects — attach anyway?")
        let model = AgentTreeModel(editing: editing)
        model.receive(snapshot(AgentTree(generatedAt: nil, chiefs: [chief("c1")], unassigned: [node("w1")], parentGone: [])))
        model.attach(child: node("w1"), to: chief("c1"))
        await waitUntil { model.pendingConfirm != nil }
        #expect(model.pendingConfirm?.message == "Different projects — attach anyway?")
        #expect(model.tree?.unassigned.map(\.id) == ["w1"])   // reverted: nothing happened yet
        #expect(model.tree?.chiefs.first?.children.isEmpty == true)
    }

    @Test func confirmingRetriesWithConfirmCrossProjectTrue() async {
        let editing = AgentTreeFakeEditing()
        editing.attachReply = .needsConfirm(message: "confirm?")
        let model = AgentTreeModel(editing: editing)
        model.receive(snapshot(AgentTree(generatedAt: nil, chiefs: [chief("c1")], unassigned: [node("w1")], parentGone: [])))
        model.attach(child: node("w1"), to: chief("c1"))
        await waitUntil { model.pendingConfirm != nil }
        editing.attachReply = .attached(warning: nil)
        model.confirmPendingAttach()
        await waitUntil { editing.attachCalls.count == 2 }
        #expect(editing.attachCalls.last == .init(child: "w1", parent: "c1", confirmCrossProject: true))
        #expect(model.pendingConfirm == nil)
    }

    @Test func cancelingAPendingConfirmLeavesTheTreeUntouched() async {
        let editing = AgentTreeFakeEditing()
        editing.attachReply = .needsConfirm(message: "confirm?")
        let model = AgentTreeModel(editing: editing)
        model.receive(snapshot(AgentTree(generatedAt: nil, chiefs: [chief("c1")], unassigned: [node("w1")], parentGone: [])))
        model.attach(child: node("w1"), to: chief("c1"))
        await waitUntil { model.pendingConfirm != nil }
        model.cancelPendingAttach()
        #expect(model.pendingConfirm == nil)
        #expect(model.tree?.unassigned.map(\.id) == ["w1"])
    }

    // MARK: - Refusal / failure

    @Test func aRefusalRevertsAndShowsTheServersMessage() async {
        let editing = AgentTreeFakeEditing()
        editing.attachReply = .refused(message: "would create a cycle")
        let model = AgentTreeModel(editing: editing)
        model.receive(snapshot(AgentTree(generatedAt: nil, chiefs: [chief("c1")], unassigned: [node("w1")], parentGone: [])))
        model.attach(child: node("w1"), to: chief("c1"))
        await waitUntil { model.errorMessage != nil }
        #expect(model.errorMessage == "would create a cycle")
        #expect(model.tree?.unassigned.map(\.id) == ["w1"])
    }

    @Test func aFailedDetachRevertsToTheChiefsChildren() async {
        let editing = AgentTreeFakeEditing()
        editing.detachReply = .failed("can't reach the dashboard")
        let model = AgentTreeModel(editing: editing)
        model.receive(snapshot(AgentTree(generatedAt: nil, chiefs: [chief("c1", children: [node("w1")])], unassigned: [], parentGone: [])))
        model.detach(child: node("w1"))
        await waitUntil { model.errorMessage != nil }
        #expect(model.tree?.chiefs.first?.children.map(\.id) == ["w1"])
        #expect(model.tree?.unassigned.isEmpty == true)
    }

    // MARK: - Guard rails independent of the display-order helper (drag & drop goes through these directly)

    @Test func attachingAChiefUnderAnotherChiefIsRefusedClientSide() async {
        let editing = AgentTreeFakeEditing()
        let model = AgentTreeModel(editing: editing)
        model.receive(snapshot(AgentTree(generatedAt: nil, chiefs: [chief("c1"), chief("c2")], unassigned: [], parentGone: [])))
        model.attach(child: chief("c2"), to: chief("c1"))
        await settleTasks()
        #expect(editing.attachCalls.isEmpty)
        #expect(model.errorMessage != nil)
    }

    @Test func attachingANodeToItselfIsANoOp() async {
        let editing = AgentTreeFakeEditing()
        let model = AgentTreeModel(editing: editing)
        model.receive(snapshot(AgentTree(generatedAt: nil, chiefs: [chief("c1")], unassigned: [node("w1")], parentGone: [])))
        model.attach(child: node("w1"), to: node("w1"))
        await settleTasks()
        #expect(editing.attachCalls.isEmpty)
    }

    @Test func attachingToAParentThatIsntAChiefIsRefusedClientSideWithNoOptimisticMove() async {
        // `movingChild` itself no-ops silently on a bad parent id — this is the defensive check one
        // level up, so a caller's mistake (a future drag-drop or picker bug) surfaces as a message
        // instead of a quiet freeze.
        let editing = AgentTreeFakeEditing()
        let model = AgentTreeModel(editing: editing)
        model.receive(snapshot(AgentTree(generatedAt: nil, chiefs: [chief("c1")], unassigned: [node("w1"), node("not-a-chief")], parentGone: [])))
        model.attach(child: node("w1"), to: node("not-a-chief"))
        await settleTasks()
        #expect(editing.attachCalls.isEmpty)
        #expect(model.errorMessage?.contains("isn't a chief") == true)
        #expect(model.tree?.unassigned.map(\.id).sorted() == ["not-a-chief", "w1"])   // untouched
    }

    // MARK: - Mid-flight snapshot race (QA-flagged: a stale revert must not clobber fresher SSE state)

    @Test func aFailedAttachDoesNotClobberAFresherSnapshotThatArrivedMidFlight() async {
        let editing = AgentTreeFakeEditing()
        editing.holdAttach = true
        editing.attachReply = .failed("network blip")
        let model = AgentTreeModel(editing: editing)
        model.receive(snapshot(AgentTree(generatedAt: nil, chiefs: [chief("c1")], unassigned: [node("w1")], parentGone: [])))
        model.attach(child: node("w1"), to: chief("c1"))   // optimistic move applied, then parked mid-flight
        await waitUntil { !editing.attachCalls.isEmpty }

        // Server-authoritative snapshot lands while the attach round trip is still outstanding —
        // says w1 already reports to c2 (e.g. another client moved it). This must win.
        let fresher = AgentTree(generatedAt: nil, chiefs: [chief("c1"), chief("c2", children: [node("w1")])], unassigned: [], parentGone: [])
        model.receive(snapshot(fresher))

        editing.releaseAttach()
        await waitUntil { model.errorMessage != nil }
        #expect(model.errorMessage == "network blip")
        #expect(model.tree?.chiefs.first { $0.id == "c2" }?.children.map(\.id) == ["w1"])   // not clobbered
    }

    @Test func aFailedDetachDoesNotClobberAFresherSnapshotThatArrivedMidFlight() async {
        let editing = AgentTreeFakeEditing()
        editing.holdDetach = true
        editing.detachReply = .failed("network blip")
        let model = AgentTreeModel(editing: editing)
        model.receive(snapshot(AgentTree(generatedAt: nil, chiefs: [chief("c1", children: [node("w1")])], unassigned: [], parentGone: [])))
        model.detach(child: node("w1"))
        await waitUntil { !editing.detachCalls.isEmpty }

        let fresher = AgentTree(generatedAt: nil, chiefs: [chief("c1"), chief("c2", children: [node("w1")])], unassigned: [], parentGone: [])
        model.receive(snapshot(fresher))

        editing.releaseDetach()
        await waitUntil { model.errorMessage != nil }
        #expect(model.errorMessage == "network blip")
        #expect(model.tree?.chiefs.first { $0.id == "c2" }?.children.map(\.id) == ["w1"])   // not clobbered
    }

    @Test func aFailedAttachStillRevertsWhenNoFresherSnapshotArrived() async {
        // Same failure, but nothing superseded the optimistic move — the old revert behavior must
        // still hold (the fix only skips the revert when it would clobber newer state).
        let editing = AgentTreeFakeEditing()
        editing.attachReply = .failed("network blip")
        let model = AgentTreeModel(editing: editing)
        model.receive(snapshot(AgentTree(generatedAt: nil, chiefs: [chief("c1")], unassigned: [node("w1")], parentGone: [])))
        model.attach(child: node("w1"), to: chief("c1"))
        await waitUntil { model.errorMessage != nil }
        #expect(model.tree?.unassigned.map(\.id) == ["w1"])
        #expect(model.tree?.chiefs.first?.children.isEmpty == true)
    }

    @Test func attachingBeforeTheTreeHasLoadedShowsADistinctMessageNotTheIsAChiefOne() async {
        let editing = AgentTreeFakeEditing()
        let model = AgentTreeModel(editing: editing)   // no snapshot received yet: tree == nil
        model.attach(child: node("w1"), to: chief("c1"))
        await settleTasks()
        #expect(editing.attachCalls.isEmpty)
        #expect(model.errorMessage == "The hierarchy hasn't loaded yet.")
        #expect(model.errorMessage?.contains("is a chief") == false)
    }
}
