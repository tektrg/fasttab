import Foundation
import Testing
@testable import AgentBar

struct AgentTreeDisplayOrderTests {
    private func node(_ id: String, children: [AgentTreeNode] = []) -> AgentTreeNode {
        AgentTreeNode(
            id: id, label: id, project: "proj", projectRoot: nil, machine: "local", paneId: nil,
            alive: true, status: nil, crossProject: false, isChiefMode: false, children: children
        )
    }

    private func goneEntry(_ id: String) -> AgentTree.ParentGoneEntry {
        AgentTree.ParentGoneEntry(node: node(id), lostParentID: "dead", lostParentLabel: "Dead Chief")
    }

    @Test func flattenOrdersParentGoneFirstThenChiefsWithChildrenThenUnassigned() {
        let tree = AgentTree(
            generatedAt: nil,
            chiefs: [node("chief-1", children: [node("w1"), node("w2")])],
            unassigned: [node("u1")],
            parentGone: [goneEntry("g1")]
        )
        let ids = AgentTreeDisplayOrder.flatten(tree).map(\.nodeID)
        #expect(ids == ["g1", "chief-1", "w1", "w2", "u1"])
    }

    @Test func multipleChiefsInterleaveWithTheirOwnChildren() {
        let tree = AgentTree(
            generatedAt: nil,
            chiefs: [
                node("chief-1", children: [node("w1")]),
                node("chief-2", children: [node("w2"), node("w3")]),
            ],
            unassigned: [], parentGone: []
        )
        let ids = AgentTreeDisplayOrder.flatten(tree).map(\.nodeID)
        #expect(ids == ["chief-1", "w1", "chief-2", "w2", "w3"])
    }

    @Test func nearestChiefAboveAChildIsItsOwnChief() {
        let tree = AgentTree(generatedAt: nil, chiefs: [node("chief-1", children: [node("w1")])], unassigned: [], parentGone: [])
        let rows = AgentTreeDisplayOrder.flatten(tree)
        #expect(AgentTreeDisplayOrder.nearestChief(above: "w1", in: rows)?.id == "chief-1")
    }

    @Test func nearestChiefAboveAnUnassignedRowIsTheLastChief() {
        let tree = AgentTree(
            generatedAt: nil,
            chiefs: [node("chief-1", children: []), node("chief-2", children: [])],
            unassigned: [node("u1")], parentGone: []
        )
        let rows = AgentTreeDisplayOrder.flatten(tree)
        #expect(AgentTreeDisplayOrder.nearestChief(above: "u1", in: rows)?.id == "chief-2")
    }

    @Test func nearestChiefAboveAParentGoneRowIsNilSinceThatSectionIsAlwaysFirst() {
        let tree = AgentTree(
            generatedAt: nil,
            chiefs: [node("chief-1", children: [])],
            unassigned: [], parentGone: [goneEntry("g1")]
        )
        let rows = AgentTreeDisplayOrder.flatten(tree)
        #expect(AgentTreeDisplayOrder.nearestChief(above: "g1", in: rows) == nil)
    }

    @Test func nearestChiefAboveTheFirstChiefItselfIsNil() {
        let tree = AgentTree(generatedAt: nil, chiefs: [node("chief-1", children: [])], unassigned: [], parentGone: [])
        let rows = AgentTreeDisplayOrder.flatten(tree)
        #expect(AgentTreeDisplayOrder.nearestChief(above: "chief-1", in: rows) == nil)
    }

    @Test func nearestChiefAboveASecondChiefIsTheFirstOne() {
        let tree = AgentTree(generatedAt: nil, chiefs: [node("chief-1", children: []), node("chief-2", children: [])], unassigned: [], parentGone: [])
        let rows = AgentTreeDisplayOrder.flatten(tree)
        #expect(AgentTreeDisplayOrder.nearestChief(above: "chief-2", in: rows)?.id == "chief-1")
    }

    @Test func nearestChiefAboveAnUnknownIdIsNil() {
        let tree = AgentTree(generatedAt: nil, chiefs: [node("chief-1", children: [])], unassigned: [], parentGone: [])
        let rows = AgentTreeDisplayOrder.flatten(tree)
        #expect(AgentTreeDisplayOrder.nearestChief(above: "ghost", in: rows) == nil)
    }
}
