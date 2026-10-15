import Foundation
import Testing
@testable import AgentBar

/// Claude Desktop's end-of-turn question (wrap_up box), detected by the dashboard
/// (`transcript_wrap_up.py`) and sent as `wrapUpQuestion` on an idle row + its "blocked" needsYou entry:
/// the row waits on the user, stays messageable, and the message card's action buttons send the message.
struct WrapUpQuestionMapperTests {
    typealias S = StatusOnlyFixtures
    typealias I = InboxFixtures

    static let question = """
    {"ask": "Start building DATA-314 with slice 1?", "recap": "Plan ready.",
     "actions": [{"label": "Start slice 1", "message": "Start DATA-314 slice 1 now."}, {"label": "Adjust plan first"}]}
    """

    static func needsYou(question: String?) -> String {
        """
        {"kind": "blocked", "paneId": null, "detail": "Start building DATA-314 with slice 1?",
         "agentSession": "\(S.desktopSession)", "source": "claude-desktop", "sinceSec": 3,
         "hookRequest": null, "wrapUpQuestion": \(question ?? "null")}
        """
    }

    static func mapped(question: String?, withEntry: Bool = true) throws -> AgentSnapshot? {
        try S.snapshot(
            agents: [I.desktopRow(messageVia: "inbox")],
            needsYou: withEntry ? [needsYou(question: question)] : []
        ).agents.first
    }

    @Test func askPresentTheRowWaitsOnYouWithTheQuestion() throws {
        let row = try #require(try Self.mapped(question: Self.question))
        #expect(row.section == .needsYou)
        #expect(row.isWaitingOnYou)
        #expect(row.statusText == "Start building DATA-314 with slice 1?")
        #expect(row.wrapUpQuestion?.actions.map(\.label) == ["Start slice 1", "Adjust plan first"])
    }

    @Test func anActionWithoutAMessageSendsItsLabel() throws {
        let row = try #require(try Self.mapped(question: Self.question))
        #expect(row.wrapUpQuestion?.actions.map(\.message) == ["Start DATA-314 slice 1 now.", "Adjust plan first"])
    }

    @Test func theRowStillTakesAnInboxMessage() throws {
        let row = try #require(try Self.mapped(question: Self.question))
        #expect(row.blocker == nil)
        #expect(row.messagesViaInbox)
        #expect(RowButtons.usableButtons(for: row).contains(.message))
    }

    @Test func noQuestionOrNoEntryMeansNoCard() throws {
        // Ask absent / user replied: the dashboard sends no question and no needsYou entry.
        let plain = try #require(try Self.mapped(question: nil, withEntry: false))
        #expect(plain.wrapUpQuestion == nil)
        #expect(!plain.isWaitingOnYou)
        #expect(plain.messagesViaInbox)
    }

    /// Desktop's `blocked: true` wrap_up leaves the session `waiting`: still the question, still messageable.
    @Test func aWaitingSessionWithAWrapUpIsShownAndMessageable() throws {
        let row = try #require(try S.snapshot(
            agents: [I.desktopRow(messageVia: "inbox", status: "waiting", hookState: "blocked")],
            needsYou: [Self.needsYou(question: Self.question)]
        ).agents.first)
        #expect(row.isWaitingOnYou)
        #expect(row.statusText == "Start building DATA-314 with slice 1?")
        #expect(row.wrapUpQuestion != nil)
        #expect(row.messagesViaInbox)
        #expect(RowButtons.usableButtons(for: row).contains(.message))
    }

    @Test func aQuestionWithoutAskOrActionsIsIgnored() throws {
        let noAsk = try #require(try Self.mapped(question: #"{"ask": "  ", "actions": [{"label": "a"}]}"#))
        #expect(noAsk.wrapUpQuestion == nil)
        let noActions = try #require(try Self.mapped(question: #"{"ask": "Go?", "actions": []}"#))
        #expect(noActions.wrapUpQuestion == nil)
    }
}

@MainActor
struct WrapUpQuestionCardTests {
    typealias I = InboxFixtures

    static func agent() throws -> AgentSnapshot {
        try #require(try WrapUpQuestionMapperTests.mapped(question: WrapUpQuestionMapperTests.question))
    }

    @Test func aButtonSendsThatActionsMessageThroughTheInbox() async throws {
        let model = MessageCardModel(sentLabelSeconds: 6, loadSessionContext: { _ in .empty })
        let source = MessageFakeSource()
        model.statusSource = source
        let agent = try Self.agent()
        #expect(model.open(agent))
        let action = try #require(model.card?.wrapUpQuestion?.actions.first)
        model.pressWrapUpAction(action)
        await source.waitForRequests(1)
        #expect(source.screenReads == 0)
        #expect(source.sent == [.init(rowId: StatusOnlyFixtures.desktopSession, text: "Start DATA-314 slice 1 now.", confirmed: false)])
        model.pressWrapUpAction(action)   // a second press while sending is ignored
        #expect(source.sent.count == 1)
        source.reply(.sent(queued: false))
        await waitUntil { !model.isOpen }
    }

    @Test func anActionNotOnTheCardIsIgnored() throws {
        let model = MessageCardModel(sentLabelSeconds: 6, loadSessionContext: { _ in .empty })
        let source = MessageFakeSource()
        model.statusSource = source
        #expect(model.open(try Self.agent()))
        model.pressWrapUpAction(.init(label: "x", message: "rm"))
        #expect(model.card?.phase == .editing)
        #expect(source.sent.isEmpty)
    }
}

/// The real `/api/state` captured while a Claude Desktop wrap_up question was pending
/// (`Fixtures/wrap-up-pending-state.json`, trimmed to that session). Live test 2026-10-15: the data reached
/// the app intact and the row sat in Needs you, but with no blocker it drew no button until selected — it
/// looked like any idle row. The row now carries a red Answer that is visible unselected.
struct WrapUpLivePayloadTests {
    static func row() throws -> AgentSnapshot {
        let snapshot = try HookBridgeLivePayloadTests.snapshot("wrap-up-pending-state")
        let rows = AgentListBuilder.presentation(snapshot: snapshot, query: "", frecency: [:], now: Date()).rows
        #expect(rows.first == .header(.needsYou))
        return try #require(snapshot.agents.first { $0.wrapUpQuestion != nil })
    }

    @Test func theCapturedQuestionIsWaitingOnYouWithAVisibleRedAnswer() throws {
        let row = try Self.row()
        #expect(row.section == .needsYou)
        #expect(row.isWaitingOnYou)
        #expect(row.statusText == "Probe 2: please don't answer for ~60 seconds.")
        let first = try #require(RowButtons.available(for: row).first)
        #expect(first.button == .message && first.answersWrapUp && first.isBlockedAction && first.label == "Answer")
        #expect(row.wrapUpQuestion?.actions.map(\.message) == ["Waited 60s; read probe 2."])
    }
}

/// A new wrap_up question pops the corner tab (and plays the answer sound) the way a blocker does — once
/// per question, through the same `BlockedEpisodeTracker` / `ArrivalSoundPlanner` path.
struct WrapUpQuestionAnnounceTests {
    static func pops(_ tracker: inout BlockedEpisodeTracker, _ needsYou: [AgentSnapshot]) -> Bool {
        tracker.observe(needsYou)
    }

    static func agent(ask: String?) throws -> AgentSnapshot {
        var agent = StatusOnlyFixtures.desktopAgent()
        if let ask {
            let json = #"{"ask": "\#(ask)", "actions": [{"label": "Yes"}]}"#
            agent.wrapUpQuestion = WrapUpQuestion(try JSONDecoder().decode(DashboardWrapUpQuestion.self, from: Data(json.utf8)))
        }
        return agent
    }

    @Test func aNewQuestionPopsOnceAndNotOnRePoll() throws {
        var tracker = BlockedEpisodeTracker()
        #expect(!Self.pops(&tracker, [try Self.agent(ask: nil)]))           // baseline
        #expect(Self.pops(&tracker, [try Self.agent(ask: "Ship it?")]))      // new question
        #expect(!Self.pops(&tracker, [try Self.agent(ask: "Ship it?")]))     // re-poll
    }

    @Test func answeredThenANewQuestionPopsAgain() throws {
        var tracker = BlockedEpisodeTracker()
        _ = tracker.observe([])
        #expect(Self.pops(&tracker, [try Self.agent(ask: "Ship it?")]))
        #expect(!Self.pops(&tracker, []))                                    // answered: the agent works, leaves Needs you
        #expect(Self.pops(&tracker, [try Self.agent(ask: "Ship it?")]))      // asked again later
        #expect(Self.pops(&tracker, [try Self.agent(ask: "And slice 2?")]))  // a different question while still there
    }

    @Test func aWrapUpWithoutAskNeverPops() throws {
        var tracker = BlockedEpisodeTracker()
        _ = tracker.observe([])
        #expect(!Self.pops(&tracker, [try Self.agent(ask: nil)]))
        #expect(CornerTabContent.summary(of: [try Self.agent(ask: nil)]).blockedCount == 0)
    }

    @Test func theCornerTabStaysAndTheAnswerSoundPlays() throws {
        let asking = try Self.agent(ask: "Ship it?")
        #expect(CornerTabContent.summary(of: [asking]).blockedCount == 1)
        var planner = ArrivalSoundPlanner()
        let cue = planner.observe(arrivals: [asking], needsYou: [asking], now: Date())
        #expect(cue == .needsAnswer)
    }
}
