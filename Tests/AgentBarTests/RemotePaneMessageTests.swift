import Foundation
import Testing
@testable import AgentBar

/// Messaging a Claude pane on another machine (the Air): the Pro's hook cache never covers it, so the row has
/// no hook data, but the dashboard marks it `messageVia: "pane"` with no `messageRefusal` and types the text
/// there over ssh. AgentBar offers Message on it like the web remote (`canMessage`); Compact/Clear stay
/// hook-data only (the web's `takesQuickCommands`).
struct RemotePaneMessageTests {
    typealias S = StatusOnlyFixtures

    private func airRow(messageVia: String? = "pane", refusal: String? = nil, hasHookData: Bool = false, kind: String = "claude") -> String {
        let viaJson = messageVia.map { "\"\($0)\"" } ?? "null"
        let refusalJson = refusal.map { "\"\($0)\"" } ?? "null"
        return """
        {"paneId": "air-m1:w8:p3", "label": "air", "cwd": "/p", "hasHookData": \(hasHookData), "machine": "air-m1",
         "agentSession": "s-air", "source": "herdr", "rowId": "s-air", "agentKind": "\(kind)",
         "messageVia": \(viaJson), "messageRefusal": \(refusalJson)}
        """
    }

    private func row(_ json: String, needsYou: [String] = []) throws -> AgentSnapshot {
        try #require(try S.snapshot(agents: [json], needsYou: needsYou).agents.first)
    }

    private func offersMessage(_ agent: AgentSnapshot) -> Bool {
        RowButtons.available(for: agent).contains { $0.button == .message }
    }

    @Test func anAirPaneRowWithoutHookDataIsOfferedMessage() throws {
        let agent = try row(airRow())
        #expect(!agent.hasHookData)
        #expect(agent.messagesViaPane)
        #expect(offersMessage(agent))
        #expect(MessageRoute(agent: agent) == .pane(paneId: "air-m1:w8:p3"))
    }

    @Test func anAirRowsScreenActivityIsItsActivityClockButNotHookData() throws {
        let json = airRow().replacingOccurrences(of: "\"machine\": \"air-m1\",", with: "\"machine\": \"air-m1\", \"screenActivitySec\": 42.0,")
        let agent = try row(json)
        #expect(agent.screenActivitySeconds == 42)
        #expect(agent.activitySeconds == 42)
        #expect(agent.secondsInStatus == nil)
        #expect(!agent.hasHookData)
    }

    @Test func anAirRowWithoutScreenActivityHasNoActivityClock() throws {
        let agent = try row(airRow())
        #expect(agent.activitySeconds == nil)
    }

    @Test func anAirPaneRowTakesNoCompactOrClear() throws {
        let agent = try row(airRow())
        #expect(!RowButtons.takesQuickCommands(agent))
        #expect(!RowButtons.menuItems(for: agent).contains { $0.button == .compact || $0.button == .clear })
    }

    @Test func aRowTheDashboardRefusesIsNotOfferedMessage() throws {
        let agent = try row(airRow(refusal: "refused: gemini prompts are invisible", kind: "gemini"))
        #expect(!offersMessage(agent))
    }

    @Test func aPaneRowWithoutHookDataOrMessageViaIsNotOfferedMessage() throws {
        #expect(!offersMessage(try row(airRow(messageVia: nil))))
    }

    @Test func aBlockedAirRowIsNotOfferedMessage() throws {
        let blocked = """
        {"kind": "blocked", "urgency": 1, "label": "air", "paneId": "air-m1:w8:p3", "detail": "unconfirmed", "sinceSec": 30.0}
        """
        let agent = try row(airRow(), needsYou: [blocked])
        #expect(agent.blocker != nil)
        #expect(!offersMessage(agent))
    }

    @Test func aProHookRowIsUnchanged() throws {
        let agent = try row("""
        {"paneId": "w1:p1", "label": "pro", "cwd": "/p", "hookState": "idle", "hasHookData": true,
         "agentSession": "s-pro", "source": "herdr", "rowId": "s-pro", "agentKind": "claude",
         "messageVia": "pane", "messageRefusal": null}
        """)
        #expect(offersMessage(agent))
        #expect(RowButtons.takesQuickCommands(agent))
    }

    @Test func aStatusOnlyRowNeverReadsAsAPaneRoute() throws {
        #expect(!(try row(S.desktopRow())).messagesViaPane)
    }
}
