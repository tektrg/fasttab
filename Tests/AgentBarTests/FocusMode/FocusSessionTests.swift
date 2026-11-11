import AppKit
import Foundation
import Testing
@testable import AgentBar

/// `FocusSession` over a real `AgentPanelModel` with a fake source (never the real dashboard):
/// it opens the shared cards for the current agent and follows the queue.
@MainActor
struct FocusSessionTests {
    typealias A = AnswerFixtures
    typealias P = PermissionFixtures
    typealias F = AgentListFixtures

    private func makeRig(_ agents: [AgentSnapshot]) -> (model: AgentPanelModel, session: FocusSession) {
        let defaults = makeScratchDefaults("focus-session")
        let model = AgentPanelModel(
            store: FrecencyStore(defaults: defaults),
            triageStore: TriageStore(defaults: defaults),
            answer: AnswerCardModel(loadSessionContext: { _ in .empty }, openFile: { _ in }),
            permission: PermissionCardModel(loadSessionContext: { _ in .empty }),
            now: { F.now }
        )
        let source = PermissionFakeSource()
        source.screen = .screen(lines: P.screen(for: P.bash), readAt: F.now)
        model.statusSource = source
        model.receive(F.snapshot(agents))
        let session = FocusSession(model: model, loadContext: { _ in FocusContext(lastMessage: "hi", hasTranscript: true) })
        return (model, session)
    }

    @Test func opensTheFirstAgentsCard() {
        let (model, session) = makeRig([A.blockedAgent("q", blocker: .question(A.question())), A.blockedAgent("r", blocker: .question(A.question()))])
        #expect(session.queue.count == 2)
        #expect(model.answer.card?.agentID == session.queue.currentID)
        #expect(session.ask == .answer)
    }

    @Test func nextOpensTheNextAgentsCard() async {
        let (model, session) = makeRig([A.blockedAgent("q", blocker: .question(A.question())), A.blockedAgent("r", blocker: .question(A.question()))])
        let first = session.queue.currentID
        session.moveForward()
        #expect(session.queue.currentID != first)
        #expect(model.answer.card?.agentID == session.queue.currentID)
        let bumps = session.bumps
        session.moveForward()
        #expect(session.bumps == bumps + 1)   // no wrap: inert at the end
    }

    @Test func aBlockerWithNoCardShowsTerminalOnly() {
        let (_, session) = makeRig([A.blockedAgent("x", blocker: .questionNotAnswerable)])
        if case .terminalOnly = session.ask {} else { Issue.record("expected terminal-only, got \(session.ask)") }
    }

    @Test func agentLeavingElsewhereAdvancesThenAllClear() async {
        let (model, session) = makeRig([A.blockedAgent("q", blocker: .question(A.question())), A.blockedAgent("r", blocker: .question(A.question()))])
        let other = session.queue.agentIDs.last!
        let remaining = [A.blockedAgent(other, blocker: .question(A.question()))]
        model.receive(F.snapshot(remaining))
        await waitUntil { session.queue.currentID == other }
        #expect(model.answer.card?.agentID == other)
        model.receive(F.snapshot([]))
        await waitUntil { session.phase == .allClear }
        #expect(!model.isCardOpen)
    }

    @Test func emptyQueueIsAllClearAtOnce() {
        let (_, session) = makeRig([])
        #expect(session.phase == .allClear)
    }

    @Test func loadsContextForTheCurrentAgent() async {
        let (_, session) = makeRig([A.blockedAgent("q", blocker: .question(A.question()))])
        await waitUntil { session.contexts["q"] != nil }
        #expect(session.contexts["q"]?.lastMessage == "hi")
    }
}

struct FocusKeyTests {
    private func key(_ code: UInt16, _ chars: String = "", _ modifiers: NSEvent.ModifierFlags = []) -> FocusKey {
        FocusKey(keyCode: code, characters: chars, modifiers: modifiers)
    }

    @Test func mapsTheFocusKeys() {
        #expect(FocusKey.action(for: key(FocusKey.escapeKeyCode), isTyping: false) == .exit)
        #expect(FocusKey.action(for: key(FocusKey.returnKeyCode), isTyping: false) == .enter)
        #expect(FocusKey.action(for: key(FocusKey.returnKeyCode, "", .command), isTyping: false) == .openTerminal)
        #expect(FocusKey.action(for: key(FocusKey.leftKeyCode, "", .command), isTyping: false) == .previousAgent)
        #expect(FocusKey.action(for: key(FocusKey.rightKeyCode, "", .command), isTyping: false) == .nextAgent)
        #expect(FocusKey.action(for: key(FocusKey.upKeyCode), isTyping: false) == .move(-1))
        #expect(FocusKey.action(for: key(FocusKey.downKeyCode), isTyping: false) == .move(1))
        #expect(FocusKey.action(for: key(18, "1"), isTyping: false) == .pick(1))
        #expect(FocusKey.action(for: key(25, "9"), isTyping: false) == .pick(9))
        #expect(FocusKey.action(for: key(29, "0"), isTyping: false) == nil)
        #expect(FocusKey.action(for: key(0, "a"), isTyping: false) == nil)
    }

    /// Regression (2026-11-11): a Message card opens with its text box focused; Esc, ⌘←/⌘→ went to
    /// the box and Focus mode looked frozen. Focus's own keys must win while typing.
    @Test func focusKeysWorkWhileTypingButTheBoxKeepsTheRest() {
        #expect(FocusKey.action(for: key(FocusKey.escapeKeyCode), isTyping: true) == .exit)
        #expect(FocusKey.action(for: key(FocusKey.leftKeyCode, "", .command), isTyping: true) == .previousAgent)
        #expect(FocusKey.action(for: key(FocusKey.rightKeyCode, "", .command), isTyping: true) == .nextAgent)
        #expect(FocusKey.action(for: key(FocusKey.returnKeyCode, "", .command), isTyping: true) == .openTerminal)
        #expect(FocusKey.action(for: key(FocusKey.keypadEnterKeyCode, "", .command), isTyping: true) == .openTerminal)
        #expect(FocusKey.action(for: key(FocusKey.returnKeyCode), isTyping: true) == nil)   // the box sends
        #expect(FocusKey.action(for: key(FocusKey.returnKeyCode, "", .shift), isTyping: true) == nil)   // line break
        #expect(FocusKey.action(for: key(FocusKey.leftKeyCode), isTyping: true) == nil)
        #expect(FocusKey.action(for: key(FocusKey.upKeyCode), isTyping: true) == nil)
        #expect(FocusKey.action(for: key(18, "1"), isTyping: true) == nil)
    }
}
