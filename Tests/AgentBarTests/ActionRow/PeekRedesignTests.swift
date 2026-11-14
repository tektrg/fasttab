import SwiftUI
import Testing
@testable import AgentBar

/// Peek redesign (2026-11-14): Last message tab by default, Terminal = pane read, Tab switches,
/// message box sends through the Tab-tag compose path (validator + `sendDirect`), shared action row.
@MainActor @Suite(.serialized)
struct PeekRedesignTests {
    typealias F = AgentListFixtures

    private func makeModel(source: any AgentStatusSource, message: String? = "Shipped. **Tests pass** — push?") -> AgentPanelModel {
        let defaults = makeScratchDefaults("peek-redesign")
        let model = AgentPanelModel(
            store: FrecencyStore(defaults: defaults), triageStore: TriageStore(defaults: defaults),
            loadPeekMessage: { _ in SessionContext(latestMessage: message, planFile: nil) },
            now: { F.now }
        )
        model.statusSource = source
        return model
    }

    private func herdrAgent(_ id: String) -> AgentSnapshot {
        var agent = F.agent(id, label: "aptus-worker-fe", project: "AptusFit", section: .working)
        agent.sessionId = "s-\(id)"
        return agent
    }

    @Test func herdrRowGetsLastMessageAndTerminal() async {
        let source = MessageFakeSource()
        let model = makeModel(source: source)
        model.receive(F.snapshot([herdrAgent("a")]))
        model.select(agentID: "a")
        #expect(model.togglePeek())
        await waitUntil { model.peek?.message != .loadingLatestMessage && model.peek?.content != .loading }
        #expect(model.peek?.tab == .lastMessage)
        #expect(model.peek?.message == .latestMessage("Shipped. **Tests pass** — push?"))
        if case .screen = model.peek?.content {} else { Issue.record("no terminal screen") }
        model.togglePeekTab()
        #expect(model.peek?.tab == .terminal)
        model.selectPeekTab(.lastMessage)
        #expect(model.peek?.tab == .lastMessage)
    }

    @Test func rowWithoutSessionSaysNoTranscript() {
        let model = makeModel(source: MessageFakeSource())
        model.receive(F.snapshot([F.agent("n", section: .working)]))
        model.select(agentID: "n")
        model.togglePeek()
        #expect(model.peek?.message == .unavailable(PanePeek.noTranscriptMessage))
    }

    @Test func messageBoxValidatesThenSendsThroughSendDirect() async {
        let source = MessageFakeSource()
        let model = makeModel(source: source)
        model.receive(F.snapshot([herdrAgent("a")]))
        model.select(agentID: "a")
        model.togglePeek()
        #expect(model.peekMessageRefusal == nil)
        #expect(!model.sendFromPeek("/deploy now"))   // slash command refused by the validator, nothing sent
        #expect(!model.sendFromPeek("   "))
        #expect(model.sendFromPeek("please\npush it"))
        await source.waitForRequests(1)
        #expect(source.sent.map(\.text) == ["please push it"])   // line breaks flattened, as the card does
    }

    @Test func rendersBothTabs() async {
        let source = MessageFakeSource()
        source.screen = .screen(lines: (1...30).map { "\($0)  ⏺ Bash(swift test --filter AgentBarTests) — line \($0)" }, readAt: F.now)
        let model = makeModel(source: source, message: """
        ## Done
        Built the **shared action row** and the ⌘K menu.

        - Tests: 1822 pass
        - Renders in light and dark

        Want me to push the branch?
        """)
        model.receive(F.snapshot([herdrAgent("a")]))
        model.select(agentID: "a")
        model.togglePeek()
        await waitUntil { model.peek?.message != .loadingLatestMessage && model.peek?.content != .loading }
        guard let peek = model.peek else { Issue.record("no peek"); return }
        for width in [680.0, 420.0] {
            await renderLightDark(PanePeekView(model: model, peek: peek, bodyHeight: 460), size: CGSize(width: width, height: 460), name: "peek-message-\(Int(width))")
        }
        model.togglePeekTab()
        guard let terminal = model.peek else { return }
        await renderLightDark(PanePeekView(model: model, peek: terminal, bodyHeight: 460), size: CGSize(width: 680, height: 460), name: "peek-terminal-680")
    }
}
