import Foundation
import Testing
@testable import AgentBar

/// What the mappers carry from the dashboard payload for the row buttons, and
/// the wording of Needs-you rows now that finished agents share the section.
struct RowActionMapperTests {
    private let healthy = try! StatusFixtures.snapshot("state-healthy")

    private func snapshot(editing edit: @escaping (inout [String: Any]) -> Void) throws -> StatusSnapshot {
        try StatusSnapshotBuilder.snapshot(
            fromJSON: StatusFixtures.data("state-healthy", editing: edit), fetchedAt: StatusFixtures.serverNow
        )
    }

    private func editAgents(_ change: @escaping (inout [[String: Any]]) -> Void) -> (inout [String: Any]) -> Void {
        { object in
            var computed = object["computed"] as! [String: Any]
            var agents = computed["agents"] as! [[String: Any]]
            change(&agents)
            computed["agents"] = agents
            object["computed"] = computed
        }
    }

    // MARK: - Row text

    @Test func aFinishedAgentShowsItsRecapNotAPrompt() throws {
        let finished = try #require(healthy.agent(labelled: "agent-four"))
        #expect(finished.section == .needsYou)
        #expect(finished.statusText.contains("recap"))
    }

    @Test func aRealPromptStillShowsTheQuestion() throws {
        #expect(try #require(healthy.agent(labelled: "agent-one")).statusText == "Storage choice")
        #expect(try #require(healthy.agent(labelled: "agent-two")).statusText == "Do you want to proceed?")
    }

    @Test func aNeedsYouDetailBeatsTheStaleScreenLine() throws {
        // A hook-preview question ("options loading"): no question title yet, the
        // screen line is left over from before, the dashboard's detail is current.
        let result = try snapshot { object in
            editAgents { agents in
                agents[1]["screenSignal"] = "stale line from the previous screen"
                agents[1]["screenQuestion"] = NSNull()
            }(&object)
            var computed = object["computed"] as! [String: Any]
            var needsYou = computed["needsYou"] as! [[String: Any]]
            needsYou[1]["detail"] = "Which option? (options loading)"
            computed["needsYou"] = needsYou
            object["computed"] = computed
        }
        #expect(try #require(result.agent(labelled: "agent-two")).statusText == "Which option? (options loading)")
    }

    @Test func withoutADetailTheScreenLineIsStillUsed() throws {
        let result = try snapshot { object in
            editAgents { agents in agents[1]["screenSignal"] = "Allow this command?" }(&object)
            var computed = object["computed"] as! [String: Any]
            var needsYou = computed["needsYou"] as! [[String: Any]]
            needsYou[1]["detail"] = NSNull()
            computed["needsYou"] = needsYou
            object["computed"] = computed
        }
        #expect(try #require(result.agent(labelled: "agent-two")).statusText == "Allow this command?")
    }

    // MARK: - Live rows carry what Done needs

    @Test func liveRowsCarryTheRowIdAndTheServersStopAndCloseVerdicts() throws {
        let agent = try #require(healthy.agent(labelled: "agent-one"))
        #expect(agent.rowId == StatusFixtures.sessionId(1))
        #expect(agent.actions.stop == ActionAvailability(isEnabled: true, needsConfirm: true, reason: "blocked · 3 uncommitted files · 10.0 MB"))
        #expect(agent.actions.close.needsConfirm)
    }

    @Test func aRowWithoutActionsInThePayloadIsLeftUsableBecauseTheServerReChecks() throws {
        let result = try snapshot(editing: editAgents { agents in agents[3].removeValue(forKey: "actions") })
        #expect(try #require(result.agent(labelled: "agent-four")).actions == .unknown)
    }

    @Test func aRefusedStopIsCarriedWithItsReason() throws {
        let result = try snapshot(editing: editAgents { agents in
            agents[3]["actions"] = ["stop": ["enabled": false, "needsConfirm": false, "reason": "refused: dev-server panes are out of scope"]]
        })
        let stop = try #require(result.agent(labelled: "agent-four")).actions.stop
        #expect(!stop.isEnabled)
        #expect(stop.reason == "refused: dev-server panes are out of scope")
    }

    // MARK: - The stopped pane (second step of Done)

    private func withStoppedPane(note: String, closeEnabled: Bool) -> (inout [String: Any]) -> Void {
        { object in
            var board = object["board"] as! [String: Any]
            var rows = board["rows"] as! [[String: Any]]
            let index = rows.firstIndex { ($0["rowId"] as? String) == StatusFixtures.sessionId(101) }!
            rows[index]["endedNote"] = note
            var actions = rows[index]["actions"] as! [String: Any]
            actions["close"] = ["enabled": closeEnabled, "needsConfirm": false, "reason": "stopped · one click"]
            rows[index]["actions"] = actions
            board["rows"] = rows
            object["board"] = board
        }
    }

    @Test func aStoppedAgentWhosePaneIsOpenStaysAsAnEndedRowWithClosePane() throws {
        let result = try snapshot(editing: withStoppedPane(note: "ended · stopped by you", closeEnabled: true))
        let stopped = try #require(result.agents(in: .ended).first { $0.id == StatusFixtures.sessionId(101) })
        #expect(stopped.statusText == "Stopped — pane still open")
        #expect(stopped.canFocus)
        #expect(stopped.rowId == StatusFixtures.sessionId(101))
        #expect(RowButtons.available(for: stopped).map(\.button) == [.closePane])
    }

    @Test func anEndedRowWithAnOpenPaneThatWasNotStoppedByUsSaysSo() throws {
        let result = try snapshot(editing: withStoppedPane(note: "ended", closeEnabled: true))
        let row = try #require(result.agents(in: .ended).first { $0.id == StatusFixtures.sessionId(101) })
        #expect(row.statusText == "Ended — pane still open")
    }

    @Test func aPlainEndedRowHasNoButtonsAndCannotBeFocused() throws {
        let plain = try #require(healthy.agents(in: .ended).first)
        #expect(!plain.canFocus)
        #expect(RowButtons.available(for: plain).isEmpty)
        #expect(plain.statusText == "ended")
    }

    @Test func afterCloseTheRowDisappears() throws {
        let result = try snapshot(editing: withStoppedPane(note: "ended · closed by you", closeEnabled: false))
        #expect(!result.agents(in: .ended).contains { $0.id == StatusFixtures.sessionId(101) })
    }
}
