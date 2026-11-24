import Foundation
import IndieAgentSessions
import Testing
@testable import AgentBar

struct AntigravityAgentTests {
    private static func decodeAgent(_ json: String) throws -> DashboardAgent {
        try JSONDecoder().decode(DashboardAgent.self, from: Data(json.utf8))
    }

    private static func decodeNeedsYou(_ json: String) throws -> DashboardNeedsYou {
        try JSONDecoder().decode(DashboardNeedsYou.self, from: Data(json.utf8))
    }

    @Test func mapsWorkingAntigravityRowAsFirstClassNonClaudeStatusOnlyHost() throws {
        let raw = try Self.decodeAgent("""
        {
            "rowId": "ag:conv-123",
            "label": "Refactor auth flow",
            "cwd": "/Users/me/01_Project/my-app",
            "source": "antigravity",
            "agentKind": "antigravity",
            "agentSession": "conv-123",
            "hasHookData": true,
            "hookState": "working",
            "hookSinceSec": 14,
            "openUrl": "antigravity://conversation/conv-123"
        }
        """)
        let mapped = LiveAgentMapper.map(agents: [raw], needsYou: [], board: .empty)
        #expect(mapped.count == 1)
        let agent = mapped[0]
        #expect(agent.id == "conv-123")
        #expect(agent.host == .antigravity(openURL: URL(string: "antigravity://conversation/conv-123")))
        #expect(agent.host.badgeText == "Antigravity")
        #expect(agent.section == .working)
        #expect(agent.isClaude == false)
        #expect(agent.isBestGuessNonClaudePane == false)
        #expect(agent.canFocus == true)
        #expect(agent.paneId == nil)
        #expect(agent.actions == .none)
    }

    @Test func mapsBlockedAntigravityQuestionRowAndOffersOpenInAntigravity() throws {
        let raw = try Self.decodeAgent("""
        {
            "rowId": "ag:conv-q",
            "label": "Pick database",
            "cwd": "/Users/me/01_Project/my-app",
            "source": "antigravity",
            "agentKind": "antigravity",
            "agentSession": "conv-q",
            "hasHookData": true,
            "hookState": "blocked",
            "hookReason": "Which database should we use?",
            "transcriptQuestion": { "header": "Question", "question": "Which database should we use?", "questionCount": 1 }
        }
        """)
        let ny = try Self.decodeNeedsYou("""
        {
            "kind": "blocked",
            "agentSession": "conv-q",
            "detail": "Which database should we use?",
            "sinceSec": 8
        }
        """)
        let mapped = LiveAgentMapper.map(agents: [raw], needsYou: [ny], board: .empty)
        #expect(mapped.count == 1)
        let agent = mapped[0]
        #expect(agent.section == .needsYou)
        #expect(agent.awaitsPrompt == true)
        #expect(agent.blockedOnYou == .questionNotAnswerable)
        #expect(agent.asksTheUser == true)
        #expect(agent.statusText.contains("Which database should we use?"))

        let specs = RowButtons.available(for: agent)
        let buttons = specs.map(\.button)
        #expect(buttons.contains(.openInAntigravity))
        #expect(specs.first(where: { $0.button == .openInAntigravity })?.isBlockedAction == true)
        #expect(buttons.contains(.park))
        #expect(buttons.contains(.peek))
        #expect(!buttons.contains(.done))
        #expect(!buttons.contains(.message))
        #expect(!buttons.contains(.moreActions))
        #expect(RowButtons.menuItems(for: agent).isEmpty)

        let destination = FocusDestination(agent: agent)
        #expect(destination.isEnabled == true)
        #expect(destination.buttonTitle == "Go to Antigravity")
    }

    @Test func listSettingsToggleFiltersAntigravityIndependentlyOfClaudeOutsideHerdr() throws {
        let ag = try LiveAgentMapper.map(agents: [Self.decodeAgent("""
        {
            "rowId": "ag:c1", "label": "AG", "source": "antigravity",
            "agentSession": "c1", "hasHookData": true, "hookState": "working"
        }
        """)], needsYou: [], board: .empty)[0]
        let claudeDesktop = try LiveAgentMapper.map(agents: [Self.decodeAgent("""
        {
            "rowId": "cd:c2", "label": "CD", "source": "claude-desktop",
            "agentSession": "c2", "hasHookData": true, "hookState": "working"
        }
        """)], needsYou: [], board: .empty)[0]

        var settings = AgentListSettings.standard
        settings.showsClaudeOutsideHerdr = false
        settings.showsAntigravityAgents = true
        let filtered1 = settings.applying(to: [ag, claudeDesktop])
        #expect(filtered1.map(\.id) == ["c1"])

        settings.showsClaudeOutsideHerdr = true
        settings.showsAntigravityAgents = false
        let filtered2 = settings.applying(to: [ag, claudeDesktop])
        #expect(filtered2.map(\.id) == ["c2"])

        // Turning off "Show non-Claude panes" does not hide Antigravity (it has hook data).
        settings.showsNonClaudePanes = false
        settings.showsAntigravityAgents = true
        let filtered3 = settings.applying(to: [ag])
        #expect(filtered3.map(\.id) == ["c1"])
    }

    @Test func readsAntigravityTranscriptAndPlanArtifactThroughSessionTranscriptReaderFallback() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ag-transcript-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let claudeProjects = tmp.appendingPathComponent("claude-projects")
        let agRoot = tmp.appendingPathComponent("antigravity")
        let convId = "conv-abc-123"
        let brainDir = agRoot.appendingPathComponent("brain").appendingPathComponent(convId)
        let logsDir = brainDir.appendingPathComponent(".system_generated/logs")
        try FileManager.default.createDirectory(at: claudeProjects, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        let transcript = """
        {"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","content":"Hello"}
        {"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","content":"First reply"}
        {"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","content":"Final **markdown** answer"}
        {"step_index":3,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","content":""}
        """
        try transcript.write(to: logsDir.appendingPathComponent("transcript.jsonl"), atomically: true, encoding: .utf8)
        let planFile = brainDir.appendingPathComponent("implementation_plan.md")
        try "# My Plan\n".write(to: planFile, atomically: true, encoding: .utf8)

        let reader = SessionTranscriptReader(projectsRoot: claudeProjects, antigravityRoots: [agRoot])
        let ctx = reader.context(forSession: convId)
        #expect(ctx.latestMessage == "Final **markdown** answer")
        #expect(ctx.planFile?.standardizedFileURL == planFile.standardizedFileURL)
    }

    @MainActor
    @Test func switchCoordinatorOpensAntigravityHost() async throws {
        final class FakeAntigravityOpener: AntigravityOpening {
            var opened: [(URL?, String?)] = []
            var result = true
            func openSession(_ url: URL?) -> Bool { openSession(url, title: nil) }
            func openSession(_ url: URL?, title: String?) -> Bool {
                opened.append((url, title))
                return result
            }
        }

        let agent = try LiveAgentMapper.map(agents: [Self.decodeAgent("""
        {
            "rowId": "ag:c1", "label": "Build feature", "source": "antigravity",
            "agentSession": "c1", "hasHookData": true, "hookState": "working",
            "openUrl": "antigravity://conversation/c1"
        }
        """)], needsYou: [], board: .empty)[0]

        let opener = FakeAntigravityOpener()
        var hidden = false
        let model = AgentPanelModel()
        let coordinator = AgentSwitchCoordinator(
            model: model,
            statusSource: MessageFakeSource(),
            panel: .init(hide: { hidden = true }, show: {}, isVisible: { !hidden }),
            antigravityOpener: opener
        )

        let outcome = await coordinator.switchTo(agent)
        #expect(outcome == .switched)
        #expect(hidden == true)
        #expect(opener.opened.count == 1)
        #expect(opener.opened[0].0 == URL(string: "antigravity://conversation/c1"))
        #expect(opener.opened[0].1 == "Build feature")
    }
}
