import Foundation
import Testing
@testable import AgentBar

/// Wire -> domain decoding for the agent hierarchy: `agentTree` on `DashboardPayload`, and
/// `AgentTreeMapper`'s mapping of the wire payload into `AgentTree`.
struct AgentTreeDecodingTests {
    private func decode(_ json: String) throws -> DashboardPayload {
        try JSONDecoder().decode(DashboardPayload.self, from: Data(json.utf8))
    }

    // MARK: - Presence / absence

    @Test func absentAgentTreeKeyDecodesToNil() throws {
        let payload = try decode(#"{"computed": {"agents": [], "needsYou": []}}"#)
        #expect(payload.agentTree == nil)
        #expect(AgentTreeMapper.map(payload.agentTree) == nil)
    }

    @Test func explicitNullAgentTreeDecodesToNil() throws {
        let payload = try decode(#"{"agentTree": null, "computed": {"agents": [], "needsYou": []}}"#)
        #expect(payload.agentTree == nil)
    }

    @Test func aStringWhereAnObjectIsExpectedDecodesToNilNotAThrow() throws {
        let payload = try decode(#"{"agentTree": "nope", "computed": {"agents": [], "needsYou": []}}"#)
        #expect(payload.agentTree == nil)
    }

    @Test func anEmptyAgentTreeIsNotNil() throws {
        let payload = try decode(#"{"agentTree": {"chiefs": [], "unassigned": [], "parentGone": []}, "computed": {"agents": [], "needsYou": []}}"#)
        let tree = try #require(AgentTreeMapper.map(payload.agentTree))
        #expect(tree.isEmpty)
    }

    // MARK: - Full shape

    @Test func fullPayloadMapsChiefrenAndUnassignedAndParentGone() throws {
        let json = """
        {"agentTree": {
            "generatedAt": "2026-09-24T10:00:00Z",
            "chiefs": [{
                "id": "chief-1", "label": "Chief One", "project": "AptusFit", "projectRoot": "/repo",
                "machine": "local", "paneId": "w1:p1", "alive": true, "isChiefMode": true, "status": "supervising",
                "children": [
                    {"id": "worker-1", "label": "Worker One", "project": "AptusFit", "machine": "air-m1",
                     "paneId": "w1:p2", "alive": true, "status": "working", "crossProject": false}
                ]
            }],
            "unassigned": [
                {"id": "worker-2", "label": "Worker Two", "project": "AptusFit", "machine": "local", "alive": true}
            ],
            "parentGone": [
                {"id": "worker-3", "label": "Worker Three", "project": "AptusFit", "machine": "local", "alive": true,
                 "lostParent": {"id": "chief-dead", "label": "Dead Chief"}}
            ]
        }, "computed": {"agents": [], "needsYou": []}}
        """
        let payload = try decode(json)
        let tree = try #require(AgentTreeMapper.map(payload.agentTree))

        #expect(tree.chiefs.count == 1)
        let chief = try #require(tree.chiefs.first)
        #expect(chief.id == "chief-1")
        #expect(chief.label == "Chief One")
        #expect(chief.isChiefMode == true)
        #expect(chief.machineBadge == nil)   // local
        #expect(chief.children.count == 1)
        #expect(chief.children.first?.id == "worker-1")
        #expect(chief.children.first?.machineBadge == "Air")

        #expect(tree.unassigned.map(\.id) == ["worker-2"])

        #expect(tree.parentGone.count == 1)
        let gone = try #require(tree.parentGone.first)
        #expect(gone.node.id == "worker-3")
        #expect(gone.lostParentID == "chief-dead")
        #expect(gone.lostParentLabel == "Dead Chief")

        #expect(tree.generatedAt != nil)
    }

    // MARK: - Missing fields, one bad row doesn't cost the rest

    @Test func aChiefMissingIdOrLabelIsDroppedWithItsChildren() throws {
        let json = """
        {"agentTree": {
            "chiefs": [
                {"label": "No Id", "children": []},
                {"id": "chief-ok", "label": "OK Chief", "children": []}
            ],
            "unassigned": [], "parentGone": []
        }, "computed": {"agents": [], "needsYou": []}}
        """
        let tree = try #require(AgentTreeMapper.map(try decode(json).agentTree))
        #expect(tree.chiefs.map(\.id) == ["chief-ok"])
    }

    @Test func aWorkerMissingLabelIsDroppedNotTheWholeArray() throws {
        let json = """
        {"agentTree": {
            "chiefs": [], "parentGone": [],
            "unassigned": [{"id": "no-label"}, {"id": "worker-ok", "label": "OK"}]
        }, "computed": {"agents": [], "needsYou": []}}
        """
        let tree = try #require(AgentTreeMapper.map(try decode(json).agentTree))
        #expect(tree.unassigned.map(\.id) == ["worker-ok"])
    }

    @Test func parentGoneMissingLostParentIsDropped() throws {
        let json = """
        {"agentTree": {
            "chiefs": [], "unassigned": [],
            "parentGone": [{"id": "worker-1", "label": "Worker"}]
        }, "computed": {"agents": [], "needsYou": []}}
        """
        let tree = try #require(AgentTreeMapper.map(try decode(json).agentTree))
        #expect(tree.parentGone.isEmpty)
    }

    @Test func missingOptionalFieldsFallBackToSafeDefaults() throws {
        let json = """
        {"agentTree": {
            "chiefs": [{"id": "c1", "label": "Chief"}],
            "unassigned": [], "parentGone": []
        }, "computed": {"agents": [], "needsYou": []}}
        """
        let tree = try #require(AgentTreeMapper.map(try decode(json).agentTree))
        let chief = try #require(tree.chiefs.first)
        #expect(chief.project == "")
        #expect(chief.machine == "local")
        #expect(chief.alive == false)
        #expect(chief.isChiefMode == false)
        #expect(chief.children.isEmpty)
    }

    // MARK: - Snapshot builder wiring
    //
    // Goes through the real "state-healthy" fixture (feeds and all): a hand-rolled minimal JSON
    // here would trip `FeedHealthEvaluator` (no `hookCache`/`herdr`/`paneScreen` feeds) into `.down`,
    // which always carries a nil `agentTree` by design — that would test the wrong thing.

    @Test func statusSnapshotBuilderCarriesTheTreeThrough() throws {
        let snapshot = try StatusSnapshotBuilder.snapshot(
            fromJSON: StatusFixtures.data("state-healthy") { object in
                object["agentTree"] = ["chiefs": [["id": "c1", "label": "Chief"]], "unassigned": [Any](), "parentGone": [Any]()]
            },
            fetchedAt: StatusFixtures.serverNow
        )
        #expect(snapshot.health == .ok)
        #expect(snapshot.agentTree?.chiefs.map(\.id) == ["c1"])
    }

    @Test func statusSnapshotBuilderLeavesTreeNilWhenAbsent() throws {
        let snapshot = try StatusFixtures.snapshot("state-healthy")   // fixture predates the field
        #expect(snapshot.health == .ok)
        #expect(snapshot.agentTree == nil)
    }

    @Test func replacingAgentsCarriesTheTreeForward() {
        let tree = AgentTree(generatedAt: nil, chiefs: [], unassigned: [], parentGone: [])
        let snapshot = StatusSnapshot(agents: [], health: .ok, fetchedAt: Date(), boardIsCurrent: true, agentTree: tree)
        let replaced = snapshot.replacingAgents([])
        #expect(replaced.agentTree == tree)
    }
}
