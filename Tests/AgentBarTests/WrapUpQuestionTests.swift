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
