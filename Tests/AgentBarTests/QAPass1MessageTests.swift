import Foundation
import Testing
@testable import AgentBar

/// QA pass 1: what the Message card may type into a real agent's terminal.
@MainActor
struct QAPass1MessageTests {
    typealias F = AgentListFixtures

    private func agent() -> AgentSnapshot {
        var agent = F.agent("a", label: "agent a", project: "proj", section: .working)
        agent.sessionId = "session-1"
        return agent
    }

    private func makeModel(screen: [String]) -> (MessageCardModel, MessageFakeSource) {
        let model = MessageCardModel(now: { F.now }, loadSessionContext: { _ in .empty })
        let source = MessageFakeSource()
        source.screen = .screen(lines: screen, readAt: F.now)
        model.statusSource = source
        return (model, source)
    }

    /// A multi-select picker with one option already ticked is still a picker: typed text would answer it.
    /// (`PaneQuestionReader.question` leaves such a picker to the terminal, i.e. returns nil: the guard must not use it.)
    @Test func aMultiSelectPickerWithATickedOptionStillStopsTheSend() async {
        let rule = String(repeating: "─", count: 90)
        let screen = [rule, "  ☐ Pick", "  Which ones?", "  ❯ 1. [✔] A", "    2. [ ] B", "    3. Type something.", "    Submit", rule, "  Enter to select"]
        #expect(PaneQuestionReader.question(in: screen) == nil && PaneQuestionReader.identity(in: screen) != nil)
        let (model, source) = makeModel(screen: screen)
        model.open(agent())
        model.setDraft("hello")
        model.pressSend()
        await waitUntil { model.card?.phase == .editing }
        #expect(source.sent.isEmpty)
        #expect(model.card?.errorText == MessageCard.waitingOnYouText)
    }

    /// The dashboard leaves typed text sitting in the input box when it says "NOT SUBMITTED" (it never clears it), so
    /// a plain second Send would type the message again after the first copy and submit both as one.
    @Test func aNotSubmittedReplyWarnsThatTheTextIsStillInTheInputBoxInsteadOfOfferingAPlainRetry() async {
        let json = #"{"ok": false, "error": "NOT SUBMITTED — the text is stuck in the input box"}"#
        let reply = try! JSONDecoder().decode(DashboardSessionActionResponse.self, from: Data(json.utf8))
        guard case .uncertain(let words)? = reply.messageOutcome else {
            Issue.record("expected the manual, warned path, got \(String(describing: reply.messageOutcome))")
            return
        }
        #expect(words.contains("input box") && words.contains("twice"))
    }

    @Test func aMidSequenceFailureIsTreatedTheSameWay() throws {
        let json = #"{"ok": false, "error": "message send failed mid-sequence — herdr down"}"#
        let reply = try JSONDecoder().decode(DashboardSessionActionResponse.self, from: Data(json.utf8))
        guard case .uncertain? = reply.messageOutcome else {
            Issue.record("expected uncertain, got \(String(describing: reply.messageOutcome))")
            return
        }
    }
}

/// Text typed into a terminal must not carry keystrokes: an ESC or Ctrl-C pasted into the box would act as that key.
struct QAPass1ControlCharacterTests {
    @Test func aMessageLosesControlCharactersButKeepsItsWords() {
        #expect(MessageDraftValidator.check("hi\u{1B}[31m there\u{03}") == .ready(text: "hi[31m there"))
        #expect(MessageDraftValidator.check("a\tb") == .ready(text: "a b"))
        #expect(MessageDraftValidator.check("\u{1B}\u{03}") == .empty)
    }

    @Test func aFreeTextAnswerLosesControlCharactersToo() {
        #expect(OtherAnswerText.sendable("go\u{1B}[A on\u{04}") == "go[A on")
        #expect(OtherAnswerText.sendable("\u{03}") == nil)
    }

    @Test func planFeedbackLosesThemAndSharesTheAnswerTextRules() {
        var state = PlanCardState(prompt: PlanFixtures.box)
        state.feedbackText = "shorter\u{1B}\nplease\u{03}"
        #expect(state.feedbackToSend == "shorter please")
    }
}
