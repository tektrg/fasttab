import Foundation
import Testing
@testable import AgentBar

/// Messaging an OpenCode / Codex row (dashboard Phase 4): the dashboard marks a herdr row of that tool with
/// fresh exact status as message-eligible (`messageRefusal: null`); AgentBar sends it as a plain prompt and
/// never offers `/compact` / `/clear`, nor a leading `/` or `!`.
struct ToolMessageMapperTests {
    typealias S = StatusOnlyFixtures

    private func herdrRow(kind: String, hasHookData: Bool, refusal: String?) -> String {
        let refusalJson = refusal.map { "\"\($0)\"" } ?? "null"
        return """
        {"paneId": "w1:p1", "label": "t", "cwd": "/p", "hookState": "idle", "hasHookData": \(hasHookData),
         "agentSession": "s-1", "source": "herdr", "rowId": "s-1", "agentKind": "\(kind)", "messageRefusal": \(refusalJson)}
        """
    }

    @Test func anOpenCodeRowWithFreshStatusTakesAToolPaneMessage() throws {
        let row = try #require(try S.snapshot(agents: [herdrRow(kind: "opencode", hasHookData: true, refusal: nil)]).agents.first)
        #expect(row.messageTool == "opencode")
        #expect(MessageRoute(agent: row) == .toolPane(paneId: "w1:p1", tool: "opencode"))
        #expect(RowButtons.available(for: row).contains { $0.button == .message })
    }

    @Test func aCodexRowGetsTheSameRoute() throws {
        let row = try #require(try S.snapshot(agents: [herdrRow(kind: "codex", hasHookData: true, refusal: nil)]).agents.first)
        #expect(MessageRoute(agent: row) == .toolPane(paneId: "w1:p1", tool: "codex"))
    }

    @Test func aBestGuessRowGetsNoMessageButton() throws {
        let row = try #require(try S.snapshot(agents: [herdrRow(kind: "codex", hasHookData: false, refusal: "refused: blind")]).agents.first)
        #expect(!RowButtons.available(for: row).contains { $0.button == .message })
    }

    @Test func aRowTheDashboardRefusesGetsNoMessageButtonEvenWithHookData() throws {
        let row = try #require(try S.snapshot(agents: [herdrRow(kind: "opencode", hasHookData: true, refusal: "refused: gone")]).agents.first)
        #expect(row.messageRefusal == "refused: gone")
        #expect(!RowButtons.available(for: row).contains { $0.button == .message })
    }

    @Test func aClaudeRowIsUnchanged() throws {
        let row = try #require(try S.snapshot(agents: [herdrRow(kind: "claude", hasHookData: true, refusal: nil)]).agents.first)
        #expect(row.messageTool == nil)
        #expect(MessageRoute(agent: row) == .pane(paneId: "w1:p1"))
    }

    @Test func compactAndClearAreNeverOfferedOnAToolRow() throws {
        for kind in ["opencode", "codex"] {
            let row = try #require(try S.snapshot(agents: [herdrRow(kind: kind, hasHookData: true, refusal: nil)]).agents.first)
            #expect(!RowButtons.takesQuickCommands(row))
            #expect(!RowButtons.menuItems(for: row).contains { $0.button == .compact || $0.button == .clear })
        }
    }
}

@MainActor
struct ToolMessageDraftTests {
    @Test func aLeadingBangIsRefusedOnlyWhenAskedTo() {
        #expect(MessageDraftValidator.check("!ls", refusesShellPrefix: true) == .slashCommand)
        #expect(MessageDraftValidator.check("!ls") == .ready(text: "!ls"))
        #expect(MessageDraftValidator.check("hello !", refusesShellPrefix: true) == .ready(text: "hello !"))
    }

    @Test func theToolPaneRouteRefusesEveryLeadingCommandWithItsOwnHint() {
        var agent = AgentListFixtures.agent("a", section: .working)
        agent.messageTool = "codex"
        let model = MessageCardModel(sentLabelSeconds: 6, loadSessionContext: { _ in .empty })
        model.statusSource = MessageFakeSource()
        #expect(model.open(agent))
        #expect(model.card?.routeCaption == MessageRoute.toolPaneCaption)
        for draft in ["/compact", "/clear", "!ls"] {
            model.setDraft(draft)
            #expect(model.card?.canSend == false)
            #expect(model.card?.draftHint == MessageRoute.toolPaneCommandHint)
        }
        model.setDraft("please summarise")
        #expect(model.card?.canSend == true)
    }

    @Test func aHeadlessSlashCommandToAToolRowFailsWithoutReachingTheDashboard() async {
        var agent = AgentListFixtures.agent("a", section: .working)
        agent.messageTool = "opencode"
        let source = MessageFakeSource()
        let model = MessageCardModel(sentLabelSeconds: 6, loadSessionContext: { _ in .empty })
        model.statusSource = source
        var outcomes: [MessageSendOutcome] = []
        model.onDirectSendOutcome = { _, _, _, outcome in outcomes.append(outcome) }
        #expect(model.sendDirect(to: agent, text: "/compact"))
        await waitUntil { !outcomes.isEmpty }
        #expect(outcomes == [.failed(MessageRoute.toolPaneCommandHint)])
        #expect(source.sent.isEmpty)
    }
}
