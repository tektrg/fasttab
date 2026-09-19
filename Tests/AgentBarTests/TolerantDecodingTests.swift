import Foundation
import Testing
@testable import AgentBar

struct TolerantDecodingTests {
    private let snapshot = try! StatusFixtures.snapshot("state-malformed-rows")

    @Test func garbageRowsAreSkippedAndGoodRowsSurvive() {
        // Fixture: 3 good agents + 2 non-object entries + 1 agent with wrongly typed fields.
        #expect(snapshot.health == .ok)
        #expect(snapshot.agent(labelled: "agent-one") != nil)
        #expect(snapshot.agent(labelled: "agent-two") != nil)
        #expect(snapshot.agent(labelled: "agent-three") != nil)
    }

    @Test func wronglyTypedFieldsDegradeToNilInsteadOfDroppingTheRow() throws {
        // agent-four's hookSinceSec/label/hasHookData had the wrong types: the row
        // still exists, with those fields defaulted.
        let degraded = try #require(snapshot.agents.first { $0.id == StatusFixtures.sessionId(4) })
        #expect(degraded.label == "")
        #expect(degraded.secondsInStatus == nil)
        #expect(!degraded.hasHookData)
        #expect(degraded.section == .needsYou)
    }

    @Test func junkInNeedsYouAndBoardListsIsIgnored() {
        #expect(snapshot.agents(in: .needsYou).map(\.label).prefix(2) == ["agent-one", "agent-two"])
        #expect(snapshot.boardIsCurrent)
    }

    @Test func unknownFieldsAndMissingSectionsAreTolerated() throws {
        let json = """
        {"serverTimeTs": 1, "brandNewTopLevel": [1,2,3],
         "feeds": {"hookCache": {"refreshIntervalSec": 2, "ageSec": 0.1, "extra": true},
                   "herdr": {"refreshIntervalSec": 5, "ageSec": 0.1},
                   "paneScreen": {"refreshIntervalSec": 15, "ageSec": 0.1}},
         "computed": {"agents": [{"paneId": "w1:p1", "label": "solo", "futureField": {"x": 1}}]}}
        """
        let result = try StatusSnapshotBuilder.snapshot(fromJSON: Data(json.utf8), fetchedAt: StatusFixtures.serverNow)
        #expect(result.health == .ok)
        #expect(result.agents.map(\.label) == ["solo"])
        #expect(result.agents.first?.section == .needsYou)
        #expect(!result.boardIsCurrent)   // no board section at all: Ended/unpushed unavailable
    }

    @Test func agentsWithoutAPaneAreSkipped() throws {
        let json = """
        {"feeds": {"hookCache": {"refreshIntervalSec": 2, "ageSec": 0.1},
                   "herdr": {"refreshIntervalSec": 5, "ageSec": 0.1},
                   "paneScreen": {"refreshIntervalSec": 15, "ageSec": 0.1}},
         "computed": {"agents": [{"label": "no-pane"}, {"paneId": "", "label": "empty-pane"}]}}
        """
        let result = try StatusSnapshotBuilder.snapshot(fromJSON: Data(json.utf8), fetchedAt: StatusFixtures.serverNow)
        #expect(result.agents.isEmpty)
        #expect(result.health == .ok)
    }
}
