import Foundation
import Testing
@testable import AgentBar

/// Messaging a Claude Desktop / CLI session (status-only row, no pane) through its peer inbox:
/// dashboard `messageVia: "inbox"` (`session_inbox.py`) -> `AgentSnapshot.messagesViaInbox` ->
/// `MessageRoute.inbox`. Plus the Desktop row's Open in Claude button.
enum InboxFixtures {
    typealias S = StatusOnlyFixtures

    static func desktopRow(messageVia: String?, status: String = "idle", hookState: String = "idle") -> String {
        let via = messageVia.map { "\"\($0)\"" } ?? "null"
        return """
        {"paneId": null, "label": "desk", "cwd": "/Users/me/p", "hookState": "\(hookState)", "hasHookData": true,
         "agentSession": "\(S.desktopSession)", "source": "claude-desktop", "sessionStatus": "\(status)",
         "openUrl": "\(S.openUrl)", "rowId": "\(S.desktopSession)", "messageVia": \(via)}
        """
    }

    static func cliRow(messageVia: String?) -> String {
        let via = messageVia.map { "\"\($0)\"" } ?? "null"
        return """
        {"paneId": null, "label": "cli", "cwd": "/tmp/x", "hookState": "working", "hasHookData": true,
         "agentSession": "\(S.cliSession)", "source": "claude-cli", "sessionStatus": "busy",
         "tmuxTarget": null, "openUrl": null, "rowId": "\(S.cliSession)", "messageVia": \(via)}
        """
    }

    static func inboxAgent(section: AgentSection = .needsYou, host: AgentHost = .claudeDesktop(openURL: URL(string: S.openUrl))) -> AgentSnapshot {
        var agent = S.desktopAgent(section: section)
        agent.host = host
        agent.messagesViaInbox = true
        return agent
    }
}

struct InboxMapperTests {
    typealias I = InboxFixtures
    typealias S = StatusOnlyFixtures

    @Test func anIdleDesktopRowWithAnInboxTakesMessages() throws {
        let row = try #require(try S.snapshot(agents: [I.desktopRow(messageVia: "inbox")]).agents.first)
        #expect(row.messagesViaInbox)
        #expect(MessageRoute(agent: row) == .inbox)
    }

    @Test func aWaitingDesktopRowDoesNotTakeMessagesUntilAnswered() throws {
        let snapshot = try S.snapshot(
            agents: [I.desktopRow(messageVia: "inbox", status: "waiting", hookState: "blocked")],
            needsYou: [S.desktopWaitingNeedsYou]
        )
        #expect(snapshot.agents.first?.messagesViaInbox == false)
    }

    @Test func noInboxFromAnOlderDashboardOrAnUnsupportedSession() throws {
        #expect(try S.snapshot(agents: [S.desktopRow(status: "idle", hookState: "idle")]).agents.first?.messagesViaInbox == false)
        #expect(try S.snapshot(agents: [I.desktopRow(messageVia: nil)]).agents.first?.messagesViaInbox == false)
    }

    @Test func aCliRowWithAnInboxTakesMessagesToo() throws {
        let row = try #require(try S.snapshot(agents: [I.cliRow(messageVia: "inbox")]).agents.first)
        #expect(row.messagesViaInbox)
    }

    @Test func aHerdrRowNeverUsesTheInbox() throws {
        let herdr = """
        {"paneId": "w1:p1", "label": "h", "cwd": "/p", "hookState": "working", "hasHookData": true,
         "agentSession": "h-1", "source": "herdr", "rowId": "h-1", "messageVia": "inbox"}
        """
        let row = try #require(try S.snapshot(agents: [herdr]).agents.first)
        #expect(!row.messagesViaInbox)
        #expect(MessageRoute(agent: row) == .pane(paneId: "w1:p1"))
    }
}

struct InboxRowButtonTests {
    typealias I = InboxFixtures

    @Test func anIdleInboxDesktopRowOffersOpenInClaudeThenMessageWithTheCaption() {
        let row = I.inboxAgent()
        let specs = RowButtons.available(for: row)
        #expect(specs.map(\.button) == [.peek, .park, .openInClaude, .message])
        #expect(specs.last?.hint == MessageRoute.inboxCaption)
        #expect(RowButtons.isPressable(.message, on: row))
    }

    @Test func compactAndClearAreNeverOfferedOnAnInbox() {
        for section in [AgentSection.needsYou, .working, .parked] {
            let row = I.inboxAgent(section: section)
            #expect(!RowButtons.menuItems(for: row).contains { $0.button == .compact || $0.button == .clear })
            #expect(!RowButtons.isPressable(.compact, on: row))
            #expect(!RowButtons.isPressable(.clear, on: row))
        }
    }

    @Test func aWorkingInboxCliRowOffersMessageButNoOpenInClaude() {
        let row = I.inboxAgent(section: .working, host: .claudeCLI(tmuxTarget: nil))
        #expect(RowButtons.available(for: row).map(\.button) == [.message])
    }

    @Test func aPaneMessageButtonHasNoCaption() {
        let row = AgentListFixtures.agent("a", section: .working)
        #expect(RowButtons.available(for: row).first { $0.button == .message }?.hint == nil)
    }

    @Test func openInClaudeActivatesTheRowLikeEnter() {
        #expect(RowActionMachine.plan(pressing: .openInClaude, current: nil) == .openTerminal)
    }
}

struct InboxDraftTests {
    @Test func anInboxRefusesEverySlashCommand() {
        #expect(MessageDraftValidator.check("/compact") == .ready(text: "/compact"))
        #expect(MessageDraftValidator.check("/compact", allowsQuickCommands: false) == .slashCommand)
        #expect(MessageDraftValidator.check("/clear", allowsQuickCommands: false) == .slashCommand)
        #expect(MessageDraftValidator.check("plain text", allowsQuickCommands: false) == .ready(text: "plain text"))
    }
}

@MainActor
struct InboxMessageCardTests {
    typealias I = InboxFixtures

    private func makeModel() -> (MessageCardModel, MessageFakeSource, [MessageSendOutcome]) {
        let model = MessageCardModel(sentLabelSeconds: 6, loadSessionContext: { _ in .empty })
        let source = MessageFakeSource()
        model.statusSource = source
        return (model, source, [])
    }

    @Test func theCardOpensOnAnInboxRowWithTheCaptionAndSendsWithoutReadingAPane() async {
        let (model, source, _) = makeModel()
        #expect(model.open(I.inboxAgent()))
        #expect(model.card?.route == .inbox)
        #expect(model.card?.routeCaption == MessageRoute.inboxCaption)
        model.setDraft("please summarise")
        model.pressSend()
        await source.waitForRequests(1)
        #expect(source.screenReads == 0)
        #expect(source.sent == [.init(rowId: StatusOnlyFixtures.desktopSession, text: "please summarise", confirmed: false)])
        source.reply(.sent(queued: false))
        await waitUntil { !model.isOpen }
    }

    @Test func theCardRefusesASlashCommandForAnInboxWithItsOwnHint() {
        let (model, _, _) = makeModel()
        model.open(I.inboxAgent())
        model.setDraft("/compact")
        #expect(model.card?.canSend == false)
        #expect(model.card?.draftHint == MessageRoute.inboxSlashCommandHint)
    }

    /// Park sends `/compact` headlessly; an inbox can't carry it, so it fails before the dashboard.
    @Test func aHeadlessSlashCommandToAnInboxFailsWithoutReachingTheDashboard() async {
        let (model, source, _) = makeModel()
        var outcomes: [MessageSendOutcome] = []
        model.onDirectSendOutcome = { _, _, _, outcome in outcomes.append(outcome) }
        #expect(model.sendDirect(to: I.inboxAgent(), text: "/compact"))
        await waitUntil { !outcomes.isEmpty }
        #expect(outcomes == [.failed(MessageRoute.inboxSlashCommandHint)])
        #expect(source.sent.isEmpty)
        #expect(source.screenReads == 0)
    }

    @Test func aPaneRowCardHasNoCaption() {
        let (model, _, _) = makeModel()
        var agent = AgentListFixtures.agent("a", section: .working)
        agent.sessionId = "s"
        #expect(model.open(agent))
        #expect(model.card?.routeCaption == nil)
    }
}
