import Foundation
import Testing
@testable import AgentBar

/// A terminal that shows what the test scripts, one screen per read (the last one repeats), and takes every
/// answer. Counts what was sent so a test can prove nothing was typed into a picker someone is answering.
final class ScriptedFormSource: AgentStatusSource, @unchecked Sendable {
    let updates = AsyncStream<StatusSnapshot> { _ in }
    private let lock = NSLock()
    private var screens: [[String]]
    private var sentAnswers: [AnswerChoice] = []
    /// Called after each answer with how many were sent: lets a test move the terminal on.
    var afterAnswer: (@Sendable (ScriptedFormSource, Int) -> Void)?

    init(screens: [[String]]) { self.screens = screens }

    var sent: [AnswerChoice] { lock.withLock { sentAnswers } }
    func show(_ next: [[String]]) { lock.withLock { screens = next } }

    func focus(paneId: String) async -> FocusResult { .success }
    func perform(_ kind: SessionActionKind, rowId: String, confirmed: Bool) async -> SessionActionOutcome { .failed("unused") }

    func paneScreen(paneId: String) async -> PaneScreenResult {
        lock.withLock {
            let lines = screens.count > 1 ? screens.removeFirst() : screens[0]
            return .screen(lines: lines, readAt: Date())
        }
    }

    func answer(paneId: String, choice: AnswerChoice, question: QuestionIdentity) async -> AnswerResult {
        let count = lock.withLock { () -> Int in sentAnswers.append(choice); return sentAnswers.count }
        afterAnswer?(self, count)
        return .sent(next: nil)
    }
}

struct FormBatchExitRowTests {
    private let form = FormFixtures.form()
    private let picks: [FormChoice] = [.options([0]), .options([1]), .options([0])]

    private func timing() -> FormBatchTiming {
        var timing = FormBatchTiming()
        timing.pause = { _ in }
        return timing
    }

    private func run(
        _ source: ScriptedFormSource, timing: FormBatchTiming? = nil,
        recorded: @escaping @Sendable (PendingQuestionForm) async -> RecordedFormAnswers? = { _ in nil }
    ) async -> FormBatchResult {
        await FormBatchDriver(
            paneId: "w1:p1", form: form, choices: picks, source: source, timing: timing ?? self.timing(),
            recordedAnswers: recorded, progress: { _, _ in }
        ).run()
    }

    /// Tab `tab` drawn as the terminal does when the cursor is on its exit row.
    private func onExitRow(tab: Int) -> [String] {
        FormFixtures.screen(form, tab: tab).map { line in
            if line.hasPrefix("  ❯ ") { return "    " + line.dropFirst(4) }
            if line == "    Next" || line == "    Submit" { return "  ❯ " + line.trimmingCharacters(in: .whitespaces) }
            return line
        }
    }

    // MARK: - Someone is at the exit row

    @Test func exitRowStateStopsWithAlreadyAnsweredReasonNotNoQuestion() async {
        let source = ScriptedFormSource(screens: [onExitRow(tab: 0)])
        let result = await run(source)
        #expect(source.sent.isEmpty)   // never typed into a question someone is answering
        #expect(!result.isComplete)
        #expect(result.stopReason?.contains("already being answered in the terminal") == true)
        #expect(result.stopReason?.contains("No question") != true)
        #expect(result.outcomes.allSatisfy { if case .notSent = $0 { true } else { false } })
    }

    @Test func aTickedMultiSelectOnScreenStopsTheSameWayWithoutRetrying() async {
        let multi = FormFixtures.form(multiSelect: [0])
        let ticked = FormFixtures.screen(multi, tab: 0).map { $0.replacingOccurrences(of: "2. [ ] Close", with: "2. [✔] Close") }
        let source = ScriptedFormSource(screens: [ticked])
        let result = await FormBatchDriver(
            paneId: "p", form: multi, choices: picks, source: source, timing: timing(), progress: { _, _ in }
        ).run()
        #expect(source.sent.isEmpty && !result.isComplete)
        #expect(result.stopReason?.contains("already being answered in the terminal") == true)
    }

    @Test func aStaleRedrawOfTheQuestionJustAnsweredIsWaitedOutNotMistakenForSomeoneAnswering() async {
        // After question 1 lands the terminal still draws it once more, ticked and on its exit row; then question 2.
        let source = ScriptedFormSource(screens: [FormFixtures.screen(form, tab: 0), onExitRow(tab: 0), FormFixtures.screen(form, tab: 1),
                                                  FormFixtures.screen(form, tab: 2), FormFixtures.goneScreen])
        let result = await run(source)
        #expect(result.isComplete && source.sent.count == 3)
    }

    // MARK: - The form is gone after a landed answer

    private func goneAfterFirstAnswer() -> ScriptedFormSource {
        ScriptedFormSource(screens: [FormFixtures.screen(form, tab: 0), FormFixtures.reviewScreen(form)])
    }

    private let recordedPicks = ["Just clear it (Recommended)", "Done returns, Parked stays", "Yes, for Needs you (Recommended)"]

    @Test func noQuestionAfterLandedAnswerButTranscriptResolvedReportsRecordedAnswers() async {
        let source = goneAfterFirstAnswer()
        let recorded = RecordedFormAnswers(answers: [0: recordedPicks[0], 1: recordedPicks[1], 2: recordedPicks[2]])
        let result = await run(source, recorded: { _ in recorded })
        #expect(source.sent.count == 1)   // question 2 was never typed
        let report = FormBatchReport.summary(result, form: form)
        #expect(report.hasPrefix("The form was submitted."))
        #expect(report.contains("Recorded answers:"))
        #expect(report.contains("question 1 (Done means) → Just clear it (Recommended)"))
        #expect(report.contains("question 2 (Comes back) → Done returns, Parked stays"))
        #expect(!report.contains("Not attempted") && !report.contains("check it"))
        #expect(!result.isComplete)   // the card stays and shows the record
        #expect(result.outcomes.allSatisfy { if case .recorded(_, let chose) = $0 { chose == nil } else { false } })
    }

    @Test func aRecordedAnswerThatDiffersFromTheDraftIsFlagged() async {
        let source = goneAfterFirstAnswer()
        // The user chose "Done returns, Parked stays" for question 2; the terminal recorded option 1 (a stray Enter).
        let recorded = RecordedFormAnswers(answers: [0: recordedPicks[0], 1: "Back to Needs you (Recommended)", 2: recordedPicks[2]])
        let result = await run(source, recorded: { _ in recorded })
        let report = FormBatchReport.summary(result, form: form)
        #expect(report.contains("You chose \"Done returns, Parked stays\" but the terminal recorded \"Back to Needs you (Recommended)\""))
        #expect(report.contains("check it"))
        guard case .recorded(_, let chose) = result.outcomes[1] else { Issue.record("expected .recorded"); return }
        #expect(chose == "Done returns, Parked stays")
        guard case .recorded(_, let firstChose) = result.outcomes[0] else { Issue.record("expected .recorded"); return }
        #expect(firstChose == nil)
    }

    @Test func aTranscriptThatCannotTellKeepsTheStopWithNewWording() async {
        let source = goneAfterFirstAnswer()
        let result = await run(source, recorded: { _ in nil })
        #expect(source.sent.count == 1)
        let report = FormBatchReport.summary(result, form: form)
        #expect(report.contains("may already be submitted or being answered in the terminal"))
        #expect(report.contains("Sent: question 1 (Done means)."))
        #expect(report.contains("Not attempted: question 2 (Comes back), question 3 (Alerts)."))
        #expect(report.contains("Nothing was resent"))
    }

    @Test func theTranscriptIsAskedAFewTimesBecauseItLagsTheTerminal() async {
        let calls = CallCounter()
        let recorded = RecordedFormAnswers(answers: [0: recordedPicks[0], 1: recordedPicks[1], 2: recordedPicks[2]])
        let result = await run(goneAfterFirstAnswer(), recorded: { _ in
            calls.bump() < 2 ? nil : recorded
        })
        #expect(calls.count == 3)
        #expect(FormBatchReport.summary(result, form: form).hasPrefix("The form was submitted."))
    }
}

final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    /// Returns how many calls came before this one.
    func bump() -> Int { lock.withLock { defer { value += 1 }; return value } }
}
