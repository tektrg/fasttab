import Foundation
import Testing
@testable import AgentBar

/// Where "Last message" is read from: this Mac's transcript, or the dashboard for a row on another
/// machine (the Air, Oracle), with the short screen scrape as the fallback.
struct LatestMessageSourceTests {
    @Test func aBareOrHerdrShapedPaneIsLocal() {
        #expect(LatestMessageSource.choose(paneId: "w8:p3", rowId: "s1") == .localTranscript)
        #expect(LatestMessageSource.choose(paneId: "p_1", rowId: "s1") == .localTranscript)
        #expect(LatestMessageSource.choose(paneId: "t3:2", rowId: "s1") == .localTranscript)
        #expect(LatestMessageSource.choose(paneId: "local:w8", rowId: "s1") == .localTranscript)
        #expect(LatestMessageSource.choose(paneId: nil, rowId: "s1") == .localTranscript)
        #expect(LatestMessageSource.choose(paneId: "", rowId: "s1") == .localTranscript)
    }

    @Test func aMachinePrefixedPaneAsksTheDashboard() {
        #expect(LatestMessageSource.choose(paneId: "air-m1:w8:p3", rowId: "s-air") == .dashboard(rowId: "s-air"))
        #expect(LatestMessageSource.choose(paneId: "oracle:w1:p1", rowId: "s-o") == .dashboard(rowId: "s-o"))
    }

    @Test func aRemotePaneWithoutARowIdStaysLocal() {
        #expect(LatestMessageSource.choose(paneId: "air-m1:w8:p3", rowId: nil) == .localTranscript)
        #expect(LatestMessageSource.choose(paneId: "air-m1:w8:p3", rowId: "") == .localTranscript)
    }

    @Test func remoteTextIsTrimmedAndBlankOrFailedReadsAreEmpty() {
        #expect(LatestMessageSource.remoteContext(text: "  full text\n").latestMessage == "full text")
        #expect(LatestMessageSource.remoteContext(text: "  \n") == .empty)
        #expect(LatestMessageSource.remoteContext(text: nil) == .empty)
    }

    @Test func resolveReadsOnlyTheChosenSide() async {
        let local = SessionContext(latestMessage: "local", planFile: nil)
        let fromLocal = await LatestMessageSource.resolve(
            .localTranscript, readLocal: { local }, readRemote: { _ in "remote" })
        #expect(fromLocal == local)
        let fromRemote = await LatestMessageSource.resolve(
            .dashboard(rowId: "s-air"), readLocal: { local }, readRemote: { "full for \($0)" })
        #expect(fromRemote.latestMessage == "full for s-air")
    }

    @Test func aFailedRemoteReadLeavesTheCardOnItsScrape() async throws {
        let context = await LatestMessageSource.resolve(
            .dashboard(rowId: "s-air"), readLocal: { .empty }, readRemote: { _ in nil })
        #expect(context == .empty)
        // The card then shows the dashboard's short screen copy (AnswerCard.message fallback).
        let json = """
        {"paneId": "air-m1:w8:p3", "label": "air", "cwd": "/p", "hasHookData": false, "machine": "air-m1",
         "agentSession": "s-air", "source": "herdr", "rowId": "s-air", "agentKind": "claude"}
        """
        let agent = try #require(try StatusOnlyFixtures.snapshot(agents: [json], needsYou: []).agents.first)
        let question = AnswerableQuestion(
            title: "T", question: "Q?", isMultiSelect: false,
            options: [.init(index: 1, label: "A", description: "", isOther: false)], context: "short scrape")
        var card = AnswerCard(agent: agent, paneId: "air-m1:w8:p3", question: question)
        #expect(card.messageSource == .dashboard(rowId: "s-air"))
        card.sessionContext = context
        #expect(card.message == .text("short scrape"))
        card.sessionContext = LatestMessageSource.remoteContext(text: "the whole message")
        #expect(card.message == .text("the whole message"))
    }

    private static let airRow = """
    {"paneId": "air-m1:w8:p3", "label": "air", "cwd": "/p", "hasHookData": false, "machine": "air-m1",
     "agentSession": "s-air", "source": "herdr", "rowId": "s-air", "agentKind": "claude"}
    """

    @Test func permissionPlanAndMessageCardsChooseTheirSourceFromTheRow() throws {
        let agent = try #require(try StatusOnlyFixtures.snapshot(agents: [Self.airRow], needsYou: []).agents.first)
        let prompt = PermissionPrompt(tool: "ExitPlanMode", detail: "", title: "T", options: [.init(index: 1, label: "Yes")], cursorIndex: 1, kind: .plan, planPath: nil)
        #expect(PermissionCard(agent: agent, paneId: "air-m1:w8:p3", prompt: prompt).messageSource == .dashboard(rowId: "s-air"))
        let message = MessageCard(agent: agent, route: .pane(paneId: "air-m1:w8:p3"), rowId: "s-air")
        #expect(message.messageSource == .dashboard(rowId: "s-air"))
    }

    @Test func readUsesTheSessionIdLocallyAndFallsBackWithoutAStatusSource() async {
        let local = await LatestMessageSource.read(
            .localTranscript, sessionId: "sess",
            readLocal: { SessionContext(latestMessage: "local \($0)", planFile: nil) }, status: nil)
        #expect(local.latestMessage == "local sess")
        let remote = await LatestMessageSource.read(
            .dashboard(rowId: "s-air"), sessionId: "sess", readLocal: { _ in .empty }, status: nil)
        #expect(remote == .empty)
    }
}
