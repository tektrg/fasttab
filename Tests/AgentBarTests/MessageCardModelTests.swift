import Foundation
import Testing
@testable import AgentBar

@MainActor
struct MessageCardModelTests {
    typealias F = AgentListFixtures

    private final class Clock { var now = F.now }
    private final class Recorder {
        var notices: [String] = []
        var releasedKeyboard = 0
    }

    private struct Rig {
        let clock: Clock
        let model: MessageCardModel
        let source: MessageFakeSource
        let recorder: Recorder
    }

    private func makeRig() -> Rig {
        let clock = Clock()
        let recorder = Recorder()
        let model = MessageCardModel(now: { clock.now }, sentLabelSeconds: 6, loadSessionContext: { _ in
            SessionContext(latestMessage: "Tests pass. Anything else?", planFile: nil)
        })
        let source = MessageFakeSource()
        model.statusSource = source
        model.onNotice = { recorder.notices.append($0) }
        model.onReleaseKeyboard = { recorder.releasedKeyboard += 1 }
        return Rig(clock: clock, model: model, source: source, recorder: recorder)
    }

    private func agent(_ id: String = "a", section: AgentSection = .working) -> AgentSnapshot {
        var agent = F.agent(id, label: "agent \(id)", project: "proj", section: section)
        agent.sessionId = "session-1"
        return agent
    }

    private func sendOnce(_ rig: Rig, text: String = "please continue") async {
        rig.model.setDraft(text)
        rig.model.pressSend()
        await rig.source.waitForRequests(1)
    }

    // MARK: - Opening

    @Test func opensOnAWorkingAgentAndShowsItsLastMessage() async {
        let rig = makeRig()
        #expect(rig.model.open(agent()))
        #expect(rig.model.card?.label == "agent a")
        #expect(rig.model.card?.message == .loading)
        await waitUntil { rig.model.card?.message != .loading }
        #expect(rig.model.card?.message == .text("Tests pass. Anything else?"))
        #expect(rig.source.sent.isEmpty && rig.source.screenReads == 0)   // opening touches nothing
    }

    @Test func doesNotOpenOnRowsThatDoNotOfferMessage() {
        let rig = makeRig()
        #expect(!rig.model.open(agent(section: .ended)))
        #expect(!rig.model.open(AnswerFixtures.blockedAgent("q", blocker: .question(AnswerFixtures.question()))))
        var noRow = agent()
        noRow.rowId = nil
        #expect(!rig.model.open(noRow))
        #expect(!rig.model.isOpen)
    }

    @Test func withoutADashboardItSaysSoAndStaysClosed() {
        let rig = makeRig()
        rig.model.statusSource = nil
        #expect(!rig.model.open(agent()))
        #expect(rig.recorder.notices == [MessageCardModel.noSourceMessage])
    }

    // MARK: - Sending

    @Test func aPlainSendChecksThePaneThenSendsOnceAndClosesTheCard() async {
        let rig = makeRig()
        rig.model.open(agent())
        await sendOnce(rig)
        #expect(rig.source.sent == [.init(rowId: "a", text: "please continue", confirmed: false)])
        #expect(rig.source.screenReads == 1)
        #expect(rig.model.card?.phase == .sending)
        #expect(rig.model.sendingLabel(for: agent()) == "Sending message…")
        rig.source.reply(.sent(queued: false))
        await waitUntil { !rig.model.isOpen }
        #expect(!rig.model.isOpen)
        #expect(rig.model.sendingLabel(for: agent()) == nil)
        #expect(rig.model.sentLabel(for: agent()) == "Message sent")
        #expect(rig.recorder.notices.isEmpty)
    }

    @Test func aQueuedReplyShowsQueued() async {
        let rig = makeRig()
        rig.model.open(agent())
        await sendOnce(rig)
        rig.source.reply(.sent(queued: true))
        await waitUntil { !rig.model.isOpen }
        #expect(rig.model.sentLabel(for: agent()) == "Message queued")
    }

    @Test func theSentLabelFadesAfterItsTime() async {
        let rig = makeRig()
        rig.model.open(agent())
        await sendOnce(rig)
        rig.source.reply(.sent(queued: false))
        await waitUntil { !rig.model.isOpen }
        rig.clock.now = rig.clock.now.addingTimeInterval(7)
        #expect(rig.model.sentLabel(for: agent()) == nil)
    }

    @Test func newlinesAreFlattenedInTheTextThatGoesOut() async {
        let rig = makeRig()
        rig.model.open(agent())
        await sendOnce(rig, text: "line one\nline two\n")
        #expect(rig.source.sent.first?.text == "line one line two")
    }

    @Test func aSecondPressWhileSendingSendsNothingMore() async {
        let rig = makeRig()
        rig.model.open(agent())
        await sendOnce(rig)
        rig.model.pressSend()
        rig.model.pressSend()
        await settleTasks()
        #expect(rig.source.sent.count == 1)
    }

    @Test func nothingIsSentForAnEmptySlashOrTooLongDraft() async {
        let rig = makeRig()
        rig.model.open(agent())
        for draft in ["", "   ", "/clear", String(repeating: "a", count: 2001)] {
            rig.model.setDraft(draft)
            rig.model.pressSend()
        }
        await settleTasks()
        #expect(rig.source.sent.isEmpty)
        #expect(rig.source.screenReads == 0)
        #expect(rig.model.card?.phase == .editing)
    }

    @Test func escapeIsIgnoredWhileTheMessageIsOnItsWay() async {
        let rig = makeRig()
        rig.model.open(agent())
        await sendOnce(rig)
        rig.model.handleEscape()
        #expect(rig.model.isOpen)
        rig.source.reply(.sent(queued: false))
        await waitUntil { !rig.model.isOpen }
    }

    @Test func escapeClosesTheCardAndGivesTheKeyboardBackUnlessANoticeTakesIt() {
        let rig = makeRig()
        rig.model.open(agent())
        rig.model.consumeEscape = { true }
        rig.model.handleEscape()
        #expect(rig.model.isOpen)
        rig.model.consumeEscape = { false }
        rig.model.handleEscape()
        #expect(!rig.model.isOpen)
        #expect(rig.recorder.releasedKeyboard == 1)
    }

    // MARK: - Safety before sending

    @Test func anOpenQuestionPickerStopsTheSendBeforeAnythingIsTyped() async {
        let rig = makeRig()
        let rule = String(repeating: "─", count: 90)
        rig.source.screen = .screen(lines: [rule, "  ☐ Persist", "  Which one?", "  ❯ 1. A", "    2. B", "    3. Type something.", rule, "  Enter to select"], readAt: F.now)
        rig.model.open(agent())
        rig.model.setDraft("please continue")
        rig.model.pressSend()
        await waitUntil { rig.model.card?.phase == .editing }
        #expect(rig.source.sent.isEmpty)
        #expect(rig.model.card?.errorText == MessageCard.waitingOnYouText)
        #expect(rig.model.card?.draft == "please continue")   // the text is kept
    }

    @Test func anOpenPermissionBoxStopsTheSendToo() async {
        let rig = makeRig()
        rig.source.screen = .screen(lines: PermissionFixtures.screen(for: PermissionFixtures.bash), readAt: F.now)
        rig.model.open(agent())
        rig.model.setDraft("yes")
        rig.model.pressSend()
        await waitUntil { rig.model.card?.phase == .editing }
        #expect(rig.source.sent.isEmpty)
        #expect(rig.model.card?.errorText == MessageCard.waitingOnYouText)
    }

    @Test func aPlanBoxWrappedAtTheHerdrPaneWidthStopsTheSendToo() async {
        let rig = makeRig()
        rig.source.screen = .screen(lines: PaneQuestionReaderExitRowTests.fixtureLines("plan-box-narrow-wrapped"), readAt: F.now)
        rig.model.open(agent())
        rig.model.setDraft("keep going")
        rig.model.pressSend()
        await waitUntil { rig.model.card?.phase == .editing }
        #expect(rig.source.sent.isEmpty)
        #expect(rig.model.card?.errorText == MessageCard.waitingOnYouText)
    }

    @Test func aPickerWithTheCursorOnItsSubmitRowStopsTheSendToo() async {
        // No `❯ <digit>.` line on this screen, yet typed text would still land in the picker.
        let rig = makeRig()
        rig.source.screen = .screen(lines: PaneQuestionReaderExitRowTests.fixtureLines("user-multi-select-cursor-on-submit"), readAt: F.now)
        rig.model.open(agent())
        rig.model.setDraft("please continue")
        rig.model.pressSend()
        await waitUntil { rig.model.card?.phase == .editing }
        #expect(rig.source.sent.isEmpty)
        #expect(rig.model.card?.errorText == MessageCard.waitingOnYouText)
    }

    @Test func aMultiSelectWithOptionsAlreadyTickedStopsTheSendToo() async {
        let rig = makeRig()
        let ticked = PaneQuestionReaderExitRowTests.fixtureLines("same-form-fresh-cursor-on-opt1")
            .map { $0.replacingOccurrences(of: "2. [ ] Plan", with: "2. [✔] Plan") }
        rig.source.screen = .screen(lines: ticked, readAt: F.now)
        rig.model.open(agent())
        rig.model.setDraft("please continue")
        rig.model.pressSend()
        await waitUntil { rig.model.card?.phase == .editing }
        #expect(rig.source.sent.isEmpty)
        #expect(rig.model.card?.errorText == MessageCard.waitingOnYouText)
    }

    @Test func aPaneThatCannotBeReadMeansNothingIsSent() async {
        let rig = makeRig()
        rig.source.screen = .failure("unknown command: herdr")
        rig.model.open(agent())
        rig.model.setDraft("hello")
        rig.model.pressSend()
        await waitUntil { rig.model.card?.phase == .editing }
        #expect(rig.source.sent.isEmpty)
        #expect(rig.model.card?.errorText?.contains("Nothing was sent") == true)
    }

    // MARK: - Mid-turn confirmation, refusals, timeouts

    @Test func aBusyAgentNeedsASecondPressAndOnlyThatOneCarriesConfirm() async {
        let rig = makeRig()
        rig.model.open(agent())
        await sendOnce(rig)
        rig.source.reply(.needsConfirmation(reason: "mid-turn — the message queues"))
        await waitUntil { rig.model.card?.isConfirming == true }
        #expect(rig.model.isOpen)
        #expect(rig.model.card?.sendTitle == "Send anyway")
        #expect(rig.model.card?.errorText == nil)
        #expect(rig.model.sendingLabel(for: agent()) == nil)
        rig.model.pressSend()
        await rig.source.waitForRequests(1)
        #expect(rig.source.sent == [
            .init(rowId: "a", text: "please continue", confirmed: false),
            .init(rowId: "a", text: "please continue", confirmed: true),
        ])
        rig.source.reply(.sent(queued: true))
        await waitUntil { !rig.model.isOpen }
        #expect(rig.model.sentLabel(for: agent()) == "Message queued")
    }

    @Test func editingAfterTheMidTurnWarningDropsTheConfirmation() async {
        let rig = makeRig()
        rig.model.open(agent())
        await sendOnce(rig)
        rig.source.reply(.needsConfirmation(reason: ""))
        await waitUntil { rig.model.card?.isConfirming == true }
        rig.model.setDraft("something else")
        #expect(rig.model.card?.isConfirming == false)
        rig.model.pressSend()
        await rig.source.waitForRequests(1)
        #expect(rig.source.sent.last == .init(rowId: "a", text: "something else", confirmed: false))
    }

    @Test func aRefusalKeepsTheCardAndTheTextAndShowsTheWordsAndIsNotRetried() async {
        let rig = makeRig()
        rig.model.open(agent())
        await sendOnce(rig)
        rig.source.reply(.failed("refused: message must not start with /"))
        await waitUntil { rig.model.card?.phase == .editing }
        #expect(rig.model.card?.errorText == "refused: message must not start with /")
        #expect(rig.model.card?.draft == "please continue")
        await settleTasks()
        #expect(rig.source.sent.count == 1)
        #expect(rig.recorder.notices.isEmpty)
    }

    @Test func aTimeoutSaysItMayHaveGoneThroughAndNeverRetriesOnItsOwn() async {
        let rig = makeRig()
        rig.model.open(agent())
        await sendOnce(rig)
        rig.source.reply(.uncertain("The dashboard took too long to answer. Check the agent's terminal: the message may have gone through."))
        await waitUntil { rig.model.card?.phase == .editing }
        #expect(rig.model.card?.errorText?.contains("may have gone through") == true)
        #expect(rig.model.card?.sendTitle == "Send again")
        await settleTasks()
        #expect(rig.source.sent.count == 1)
        #expect(rig.model.sentLabel(for: agent()) == nil)
    }

    @Test func aResultForAClosedCardGoesToTheFooterInstead() async {
        let rig = makeRig()
        rig.model.open(agent())
        await sendOnce(rig)
        rig.model.close()   // e.g. the panel was dismissed mid-send
        rig.source.reply(.failed("NOT SUBMITTED: text stayed in the input box"))
        await waitUntil { !rig.recorder.notices.isEmpty }
        #expect(rig.recorder.notices == ["Message to agent a not sent: NOT SUBMITTED: text stayed in the input box"])
        #expect(!rig.model.open(agent()) || rig.model.isOpen)   // free again
    }

    @Test func aRowWithAMessageOnItsWayCannotOpenAnotherCard() async {
        let rig = makeRig()
        rig.model.open(agent())
        await sendOnce(rig)
        rig.model.close()
        #expect(!rig.model.open(agent()))
        rig.source.reply(.sent(queued: false))
        await waitUntil { rig.model.sendingLabel(for: agent()) == nil }
        #expect(rig.model.open(agent()))
    }

    // MARK: - Following the dashboard

    @Test func theCardClosesWhenItsAgentEndsOrGoesAway() {
        let rig = makeRig()
        rig.model.open(agent())
        rig.model.reconcile(with: [agent(section: .needsYou)])
        #expect(rig.model.isOpen)   // still there: a needs-you or even blocked agent keeps the draft
        rig.model.reconcile(with: [agent(section: .ended)])
        #expect(!rig.model.isOpen)
        rig.model.open(agent())
        rig.model.reconcile(with: [])
        #expect(!rig.model.isOpen)
    }

    @Test func aNewDashboardDropsEverythingIncludingLateReplies() async {
        let rig = makeRig()
        rig.model.open(agent())
        await sendOnce(rig)
        rig.model.reset()
        rig.source.reply(.sent(queued: false))
        await settleTasks()
        #expect(!rig.model.isOpen)
        #expect(rig.model.sentLabel(for: agent()) == nil)
        #expect(rig.model.sendingLabel(for: agent()) == nil)
    }
}
