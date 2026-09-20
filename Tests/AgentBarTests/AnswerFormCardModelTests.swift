import Foundation
import Testing
@testable import AgentBar

/// The answer card as a multi-question form: when it turns into one, what Submit needs, and that a batch
/// in progress is never replaced, reopened or closed underneath the user.
@MainActor
struct AnswerFormCardModelTests {
    private final class Recorder {
        var notices: [String] = []
        var answeredAgents: [String] = []
        var formLoads = 0
    }

    @MainActor private struct Rig {
        let model: AnswerCardModel
        let terminal: FakeFormTerminal
        let recorder: Recorder
        let form: PendingQuestionForm

        /// The agent as the (possibly lagging) dashboard shows it: blocked on the question of tab `tab`.
        func agent(tab: Int = 0, sessionId: String? = "session-1") -> AgentSnapshot {
            let question = PaneQuestionReader.question(in: FormFixtures.screen(form, tab: tab))!
            return AnswerFixtures.blockedAgent("a", blocker: .question(question), sessionId: sessionId)
        }

        func answerEverything() {
            for question in 0..<form.questions.count { model.clickFormRow(0, of: question) }
        }
    }

    /// `transcriptForm` is what the agent's transcript holds as pending (nil: nothing).
    private func makeRig(transcriptForm: PendingQuestionForm?, startTab: Int = 0) -> Rig {
        let form = FormFixtures.form()
        let recorder = Recorder()
        var timing = FormBatchTiming()
        timing.pause = { _ in }
        let model = AnswerCardModel(
            loadSessionContext: { _ in .empty },
            loadPendingForm: { _ in transcriptForm },
            formTiming: timing
        )
        let terminal = FakeFormTerminal(form: form, startTab: startTab)
        model.statusSource = terminal
        model.onNotice = { recorder.notices.append($0) }
        model.onAnswered = { recorder.answeredAgents.append($0) }
        return Rig(model: model, terminal: terminal, recorder: recorder, form: form)
    }

    /// A rig whose transcript holds the form.
    private func formRig(startTab: Int = 0) -> Rig { makeRig(transcriptForm: FormFixtures.form(), startTab: startTab) }

    private func openAsForm(_ rig: Rig, tab: Int = 0) async {
        #expect(rig.model.open(rig.agent(tab: tab)))
        await waitUntil { rig.model.card?.form != nil }
    }

    // MARK: - Turning into a form

    @Test func aQuestionThatIsATabOfAPendingFormOpensAsTheWholeForm() async {
        let rig = formRig()
        await openAsForm(rig)
        #expect(rig.model.card?.form?.form == rig.form)
        #expect(rig.model.card?.hintMode == .form)
        #expect(rig.model.card?.form?.answeredCount == 0)
    }

    @Test func theFormAlsoOpensWhenTheTerminalIsOnALaterTab() async {
        let rig = formRig(startTab: 1)
        await openAsForm(rig, tab: 1)
        #expect(rig.model.card?.form?.form.questions.count == 3)
    }

    @Test func withoutAPendingFormTheCardStaysTheSingleQuestionCard() async {
        let rig = makeRig(transcriptForm: nil)
        #expect(rig.model.open(rig.agent()))
        await settleTasks()
        #expect(rig.model.card?.form == nil)
        #expect(rig.model.card?.hintMode == .singleSelect)
    }

    @Test func aFormOfOneQuestionIsTheOrdinaryCard() async {
        let single = PendingQuestionForm(toolUseId: "t", questions: [FormFixtures.form().questions[0]])
        let rig = makeRig(transcriptForm: single)
        #expect(rig.model.open(rig.agent()))
        await settleTasks()
        #expect(rig.model.card?.form == nil)
    }

    @Test func aPendingFormThatDoesNotContainTheQuestionOnScreenIsIgnored() async {
        let stranger = PendingQuestionForm(toolUseId: "t", questions: FormFixtures.form().questions.map {
            FormQuestion(header: $0.header, question: "Unrelated: \($0.question)", isMultiSelect: false, options: $0.options)
        })
        let rig = makeRig(transcriptForm: stranger)
        #expect(rig.model.open(rig.agent()))
        await settleTasks()
        #expect(rig.model.card?.form == nil)
    }

    @Test func anAgentWithoutASessionNeverLooksForAForm() async {
        let rig = formRig()
        #expect(rig.model.open(rig.agent(sessionId: nil)))
        await settleTasks()
        #expect(rig.model.card?.form == nil)
    }

    // MARK: - Submit

    @Test func submitDoesNothingUntilEveryQuestionIsAnswered() async {
        let rig = formRig()
        await openAsForm(rig)
        rig.model.clickFormRow(0, of: 0)
        rig.model.clickFormRow(1, of: 1)
        rig.model.pressSend()
        rig.model.handle(.enter)
        await settleTasks()
        #expect(rig.terminal.sent.isEmpty && rig.terminal.reads == 0)
        #expect(rig.model.card?.form?.sendState == .editing)
        #expect(rig.model.card?.form?.answeredCount == 2)
    }

    @Test func submittingAnswersEveryQuestionThenClosesTheCardAndTheRowShowsSending() async {
        let rig = formRig()
        await openAsForm(rig)
        rig.model.clickFormRow(1, of: 0)
        rig.model.clickFormRow(0, of: 1)
        rig.model.clickFormRow(rig.model.card!.form!.otherRow(of: 2), of: 2)
        rig.model.setFormOtherText("something custom", of: 2)
        rig.model.pressSend()
        await waitUntil { rig.model.card == nil }
        #expect(rig.terminal.sent.map(\.choice) == [.select([2]), .select([1]), .text("something custom")])
        #expect(rig.recorder.notices.isEmpty)
        #expect(rig.recorder.answeredAgents == ["a"])
        // the dashboard, ~15s behind, may still show any tab: the row says "sending", none reopens
        for tab in 0..<3 { #expect(rig.model.isAwaiting(rig.agent(tab: tab))) }
        for tab in 0..<3 { #expect(!rig.model.open(rig.agent(tab: tab))) }
        #expect(rig.model.card == nil)
    }

    @Test func aFormWithSkippedQuestionsSaysSoInTheFooter() async {
        let rig = formRig(startTab: 1)
        await openAsForm(rig, tab: 1)
        rig.answerEverything()
        rig.model.pressSend()
        await waitUntil { rig.model.card == nil }
        #expect(rig.terminal.sent.count == 2)
        #expect(rig.recorder.notices.count == 1 && rig.recorder.notices[0].contains("Skipped question 1"))
    }

    // MARK: - While the batch runs

    @Test func aRunningBatchShowsProgressAndIsNotReplacedClosedOrEditedByTheDashboard() async {
        let rig = formRig()
        await openAsForm(rig)
        rig.answerEverything()
        let gate = AsyncGate()
        rig.terminal.beforeAnswer = { count in if count == 1 { await gate.wait() } }
        rig.model.pressSend()
        await waitUntil { rig.model.card?.form?.sendState == .sending(question: 1) }
        #expect(rig.model.card?.form?.outcomes == [.landed, .sending, .waiting])
        #expect(rig.model.card?.hintMode == .formBusy)

        let before = rig.model.card
        rig.model.reconcile(with: [rig.agent(tab: 1)])                                            // the dashboard follows the pane
        rig.model.reconcile(with: [rig.agent(tab: 2)])
        rig.model.reconcile(with: [AnswerFixtures.blockedAgent("a", blocker: .questionLoading(nil))])
        rig.model.reconcile(with: [AnswerFixtures.blockedAgent("a", blocker: nil)])                // the row flaps to "not blocked"
        rig.model.reconcile(with: [])
        #expect(rig.model.card == before)

        rig.model.handle(.escape)                                                                  // esc waits for the end of the batch
        rig.model.clickFormRow(1, of: 0)                                                           // edits are frozen
        rig.model.pressSend()                                                                      // no second batch
        rig.model.handle(.enter)
        #expect(rig.model.card == before)
        #expect(rig.model.open(rig.agent(tab: 1)) == false)                                        // the row is "sending", so no fresh single card

        gate.open()
        await waitUntil { rig.model.card == nil }
        #expect(rig.terminal.sent.count == 3)
    }

    // MARK: - When it stops

    @Test func aRefusalKeepsTheCardWithTheExactReportAndNoWayToResend() async {
        let rig = formRig()
        await openAsForm(rig)
        rig.answerEverything()
        rig.terminal.refuse(atTab: 1)
        rig.model.pressSend()
        await waitUntil { rig.model.card?.form?.sendState == .stopped }
        let form = rig.model.card?.form
        #expect(form?.outcomes == [.landed, .refused("dashboard: the answer was not accepted"), .notSent("The dashboard refused question 2 (Comes back).")])
        #expect(form?.report?.contains("Sent: question 1 (Done means).") == true)
        #expect(rig.recorder.notices == [form?.report ?? ""])
        #expect(rig.recorder.answeredAgents.isEmpty)
        #expect(rig.model.card?.hintMode == .formBusy)

        rig.model.pressSend()                                                                      // Submit is gone: nothing is resent
        rig.model.handle(.enter)
        rig.model.clickFormRow(1, of: 1)
        await settleTasks()
        #expect(rig.terminal.sent.count == 2)
        rig.model.reconcile(with: [rig.agent(tab: 2)])                                             // the report is not the dashboard's to replace
        #expect(rig.model.card?.form?.sendState == .stopped)

        rig.model.handle(.escape)
        #expect(rig.model.card == nil)
        #expect(!rig.model.isAwaiting(rig.agent(tab: 1)))                                          // the row is free again
    }

    @Test func reopeningAfterAPartialSendSkipsTheAlreadyLandedQuestionInsteadOfResendingIt() async {
        let rig = formRig()
        await openAsForm(rig)
        rig.answerEverything()
        rig.terminal.refuse(atTab: 1)
        rig.model.pressSend()
        await waitUntil { rig.model.card?.form?.sendState == .stopped }
        rig.model.handle(.escape)

        rig.terminal.refuse(atTab: 99)
        await openAsForm(rig, tab: 1)
        rig.answerEverything()
        rig.model.pressSend()
        await waitUntil { rig.model.card == nil }
        #expect(rig.terminal.sent.count == 4)   // 2 before, then question 2 and 3 only
        #expect(rig.terminal.tab == 3)
    }

    @Test func aFailureStillReachesTheFooterWhenTheCardWasClosedMeanwhile() async {
        let rig = formRig()
        await openAsForm(rig)
        rig.answerEverything()
        let gate = AsyncGate()
        rig.terminal.beforeAnswer = { count in if count == 1 { await gate.wait() } }
        rig.terminal.refuse(atTab: 1)
        rig.model.pressSend()
        await waitUntil { rig.model.card?.form?.sendState == .sending(question: 1) }
        rig.model.close()                                                                          // the panel was dismissed
        gate.open()
        await waitUntil { !rig.recorder.notices.isEmpty }
        #expect(rig.recorder.notices[0].contains("Sent: question 1"))
        #expect(rig.model.card == nil)
    }

    // MARK: - Following the dashboard while editing

    @Test func anotherTabOfTheSameFormKeepsTheCardAndTheDrafts() async {
        let rig = formRig()
        await openAsForm(rig)
        rig.model.clickFormRow(1, of: 0)
        let before = rig.model.card
        rig.model.reconcile(with: [rig.agent(tab: 1)])
        rig.model.reconcile(with: [rig.agent(tab: 2)])
        #expect(rig.model.card == before)
        #expect(rig.model.card?.form?.choice(for: 0) == .options([1]))
    }

    @Test func aQuestionOutsideTheFormTurnsTheCardIntoTheOrdinaryCardOnIt() async {
        let rig = formRig()
        await openAsForm(rig)
        let other = AnswerFixtures.question(title: "Fruit", question: "Which fruit?")
        rig.model.reconcile(with: [AnswerFixtures.blockedAgent("a", blocker: .question(other))])
        #expect(rig.model.card?.form == nil)
        #expect(rig.model.card?.state.question == other)
    }

    @Test func anIdleFormClosesWhenTheAgentIsNoLongerBlocked() async {
        let rig = formRig()
        await openAsForm(rig)
        rig.model.reconcile(with: [AnswerFixtures.blockedAgent("a", blocker: nil)])
        #expect(rig.model.card == nil)
    }

    @Test func aFormSendsNothingWhenThereIsNoDashboard() async {
        let rig = formRig()
        await openAsForm(rig)
        rig.answerEverything()
        rig.model.statusSource = nil
        rig.model.pressSend()
        await settleTasks()
        #expect(rig.model.card?.form?.sendState == .editing)
    }
}
