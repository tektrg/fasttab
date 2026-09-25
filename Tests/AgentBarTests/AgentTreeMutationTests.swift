import Foundation
import Testing
@testable import AgentBar

/// `AgentTree.movingChild`/`movingChildToUnassigned`/`node(withID:)`/`isChief` — the pure value-type
/// moves `AgentTreeModel` uses for its optimistic apply-then-revert. Kept as their own tests since
/// these are the "last line of defense" the model's doc comment mentions: they must be correct even
/// when a caller forgets to gate first.
struct AgentTreeMutationTests {
    private func node(_ id: String) -> AgentTreeNode {
        AgentTreeNode(id: id, label: id, project: "p", projectRoot: nil, machine: "local", paneId: nil, alive: true, status: nil, crossProject: false, isChiefMode: false)
    }

    private func chief(_ id: String, children: [AgentTreeNode] = []) -> AgentTreeNode {
        AgentTreeNode(id: id, label: id, project: "p", projectRoot: nil, machine: "local", paneId: nil, alive: true, status: nil, crossProject: false, isChiefMode: true, children: children)
    }

    @Test func movingAnUnassignedChildToAChiefRemovesItFromUnassigned() {
        let tree = AgentTree(generatedAt: nil, chiefs: [chief("c1")], unassigned: [node("w1")], parentGone: [])
        let moved = tree.movingChild("w1", toChiefID: "c1")
        #expect(moved.unassigned.isEmpty)
        #expect(moved.chiefs.first?.children.map(\.id) == ["w1"])
    }

    @Test func movingAChildFromOneChiefToAnotherRemovesItFromTheFirst() {
        let tree = AgentTree(generatedAt: nil, chiefs: [chief("c1", children: [node("w1")]), chief("c2")], unassigned: [], parentGone: [])
        let moved = tree.movingChild("w1", toChiefID: "c2")
        #expect(moved.chiefs.first { $0.id == "c1" }?.children.isEmpty == true)
        #expect(moved.chiefs.first { $0.id == "c2" }?.children.map(\.id) == ["w1"])
    }

    @Test func movingAParentGoneWorkerToAChiefRemovesItFromParentGone() {
        let gone = AgentTree.ParentGoneEntry(node: node("g1"), lostParentID: "dead", lostParentLabel: "Dead")
        let tree = AgentTree(generatedAt: nil, chiefs: [chief("c1")], unassigned: [], parentGone: [gone])
        let moved = tree.movingChild("g1", toChiefID: "c1")
        #expect(moved.parentGone.isEmpty)
        #expect(moved.chiefs.first?.children.map(\.id) == ["g1"])
    }

    @Test func movingAChiefIsANoOp() {
        let tree = AgentTree(generatedAt: nil, chiefs: [chief("c1"), chief("c2")], unassigned: [], parentGone: [])
        let moved = tree.movingChild("c2", toChiefID: "c1")
        #expect(moved == tree)
    }

    @Test func movingToAnUnknownParentIsANoOp() {
        let tree = AgentTree(generatedAt: nil, chiefs: [chief("c1")], unassigned: [node("w1")], parentGone: [])
        let moved = tree.movingChild("w1", toChiefID: "ghost")
        #expect(moved == tree)
    }

    @Test func movingAnUnknownChildIsANoOp() {
        let tree = AgentTree(generatedAt: nil, chiefs: [chief("c1")], unassigned: [], parentGone: [])
        let moved = tree.movingChild("ghost", toChiefID: "c1")
        #expect(moved == tree)
    }

    @Test func movingToUnassignedRemovesFromAChiefsChildren() {
        let tree = AgentTree(generatedAt: nil, chiefs: [chief("c1", children: [node("w1")])], unassigned: [], parentGone: [])
        let moved = tree.movingChildToUnassigned("w1")
        #expect(moved.chiefs.first?.children.isEmpty == true)
        #expect(moved.unassigned.map(\.id) == ["w1"])
    }

    @Test func nodeWithIDFindsAWorkerInsideAChiefsChildren() {
        let tree = AgentTree(generatedAt: nil, chiefs: [chief("c1", children: [node("w1")])], unassigned: [], parentGone: [])
        #expect(tree.node(withID: "w1")?.id == "w1")
    }

    @Test func isChiefIsTrueOnlyForAChiefRow() {
        let tree = AgentTree(generatedAt: nil, chiefs: [chief("c1", children: [node("w1")])], unassigned: [], parentGone: [])
        #expect(tree.isChief("c1") == true)
        #expect(tree.isChief("w1") == false)
    }

    @Test func isEmptyIsTrueOnlyWithNothingInAnySection() {
        #expect(AgentTree.empty.isEmpty == true)
        #expect(AgentTree(generatedAt: nil, chiefs: [chief("c1")], unassigned: [], parentGone: []).isEmpty == false)
    }
}
