import Foundation
import Testing
@testable import AgentBar

/// The three-tab screens parse with the Swift port of the dashboard's parser, tab by tab.
struct FormScreenParsingTests {
    private let form = FormFixtures.form()

    @Test func everyTabReadsAsItsOwnQuestionWithTheMergedTitle() throws {
        for (tab, question) in form.questions.enumerated() {
            let read = try #require(PaneQuestionReader.question(in: FormFixtures.screen(form, tab: tab)))
            #expect(read.title == "Done means Comes back Alerts")   // every tab shows the merged tab labels
            #expect(form.indexOfQuestion(matching: read.question) == tab)
            #expect(read.options.map(\.label).prefix(question.options.count) == question.options.map(\.label)[...])
            #expect(read.options.last?.isOther == true && read.options.count == question.options.count + 1)
            #expect(!read.isMultiSelect)
        }
    }

    @Test func aMultiSelectTabReadsAsMultiSelect() throws {
        let multi = FormFixtures.form(multiSelect: [1])
        #expect(try #require(PaneQuestionReader.question(in: FormFixtures.screen(multi, tab: 1))).isMultiSelect)
    }

    @Test func theReviewScreenAndTheGoneScreenAreNoQuestion() {
        #expect(PaneQuestionReader.question(in: FormFixtures.reviewScreen(form)) == nil)
        #expect(PaneQuestionReader.question(in: FormFixtures.goneScreen) == nil)
    }
}

/// The batch send against a terminal that behaves like the tabbed form, with no waiting.
struct FormBatchDriverTests {
    private func timing() -> FormBatchTiming {
        var timing = FormBatchTiming()
        timing.pause = { _ in }
        return timing
    }

    private func run(
        _ terminal: FakeFormTerminal, choices: [FormChoice]? = nil, timing: FormBatchTiming? = nil,
        onProgress: @escaping @Sendable @MainActor (Int, FormQuestionOutcome) -> Void = { _, _ in }
    ) async -> FormBatchResult {
        let form = terminal.form
        let picks = choices ?? form.questions.map { _ in FormChoice.options([0]) }
        return await FormBatchDriver(
            paneId: "w1:p1", form: form, choices: picks, source: terminal, timing: timing ?? self.timing(), progress: onProgress
        ).run()
    }

    @Test func everyQuestionIsAnsweredInOrderOnTheTabOnScreen() async {
        let terminal = FakeFormTerminal(form: FormFixtures.form())
        let result = await run(terminal, choices: [.options([1]), .options([0]), .options([1])])
        #expect(result.isComplete && result.outcomes == [.landed, .landed, .landed])
        #expect(terminal.sent.map(\.choice) == [.select([2]), .select([1]), .select([2])])
        // each answer carries the question the pane shows at that moment
        #expect(terminal.sent.map(\.question.question) == FormFixtures.form().questions.map { QuestionDisplayText.clean($0.question) })
        #expect(result.finalNext == nil && result.seenIdentities.count == 3)
        #expect(terminal.tab == 3)
    }

    @Test func progressIsReportedQuestionByQuestion() async {
        let log = ProgressLog()
        _ = await run(FakeFormTerminal(form: FormFixtures.form())) { question, outcome in log.add(question, outcome) }
        #expect(log.entries == [.init(0, .sending), .init(0, .landed), .init(1, .sending), .init(1, .landed), .init(2, .sending), .init(2, .landed)])
    }

    @Test func aRefusalStopsTheBatchAndReportsWhatLandedAndWhatDidNot() async {
        let terminal = FakeFormTerminal(form: FormFixtures.form())
        terminal.refuse(atTab: 1)
        let result = await run(terminal)
        #expect(!result.isComplete)
        #expect(result.outcomes == [.landed, .refused("dashboard: the answer was not accepted"), .notSent("The dashboard refused question 2 (Comes back).")])
        #expect(terminal.sent.count == 2)   // never a third request, never a resend of the second
        let report = FormBatchReport.summary(result, form: terminal.form)
        #expect(report.contains("Sent: question 1 (Done means)."))
        #expect(report.contains("Not sent question 2 (Comes back): dashboard: the answer was not accepted"))
        #expect(report.contains("Not attempted: question 3 (Alerts)."))
        #expect(report.contains("Nothing was resent"))
    }

    @Test func aRefusalOfTheFirstQuestionSendsNothingElse() async {
        let terminal = FakeFormTerminal(form: FormFixtures.form())
        terminal.refuse(atTab: 0)
        let result = await run(terminal)
        #expect(result.outcomes.first == .refused("dashboard: the answer was not accepted"))
        #expect(terminal.sent.count == 1)
    }

    @Test func aTerminalAlreadyPastEarlierQuestionsSkipsThemAndSaysSo() async {
        let terminal = FakeFormTerminal(form: FormFixtures.form(), startTab: 1)   // question 1 was answered in the terminal
        let result = await run(terminal)
        #expect(result.isComplete)
        guard case .skipped(let why) = result.outcomes[0] else { Issue.record("expected skipped"); return }
        #expect(why.contains("answer it in the terminal"))
        #expect(result.outcomes[1...] == [.landed, .landed])
        #expect(terminal.sent.count == 2)
        #expect(FormBatchReport.summary(result, form: terminal.form).contains("Skipped question 1 (Done means)"))
    }

    @Test func aTerminalThatMovesOnWhileWeWaitSkipsWhatItPassed() async {
        let terminal = FakeFormTerminal(form: FormFixtures.form())
        // after the first answer lands the user also answers question 2 in the terminal
        terminal.beforeRead = { terminal in if terminal.sent.count == 1, terminal.tab == 1 { terminal.moveTo(tab: 2) } }
        let result = await run(terminal)
        #expect(result.isComplete)
        #expect(result.outcomes[0] == .landed)
        guard case .skipped = result.outcomes[1] else { Issue.record("expected skipped"); return }
        #expect(result.outcomes[2] == .landed)
    }

    @Test func aQuestionThatIsNotInTheTranscriptFormStopsBeforeAnythingIsTyped() async {
        let terminal = FakeFormTerminal(form: FormFixtures.form())
        let stranger = PendingQuestionForm(toolUseId: "other", questions: FormFixtures.form().questions.map {
            FormQuestion(header: $0.header, question: "Something else entirely: \($0.header)?", isMultiSelect: false, options: $0.options)
        })
        let result = await FormBatchDriver(
            paneId: "p", form: stranger, choices: stranger.questions.map { _ in .options([0]) }, source: terminal,
            timing: timing(), progress: { _, _ in }
        ).run()
        #expect(!result.isComplete && terminal.sent.isEmpty)
        #expect(result.stopReason?.contains("not part of this form") == true)
        #expect(result.outcomes.allSatisfy { if case .notSent = $0 { true } else { false } })
    }

    @Test func aSlowTerminalIsWaitedForButOnlyABoundedNumberOfReads() async {
        let terminal = FakeFormTerminal(form: FormFixtures.form())
        terminal.stayStale(reads: 3)   // after the first answer, three reads still show tab 1
        let done = await run(terminal)
        #expect(done.isComplete)

        let stuck = FakeFormTerminal(form: FormFixtures.form())
        stuck.stayStale(reads: 1000)
        var patience = timing()
        patience.readsPerStep = 4
        let result = await run(stuck, timing: patience)
        #expect(!result.isComplete && result.outcomes[0] == .landed)
        #expect(result.stopReason?.contains("did not move on from question 1") == true)
        #expect(stuck.sent.count == 1)
        #expect(stuck.reads <= 1 + 4)   // 1 for the first step + 4 for the second
    }

    @Test func anUnreadableTerminalStopsWithoutTypingAnything() async {
        let terminal = FakeFormTerminal(form: FormFixtures.form())
        terminal.failReads("unknown command: herdr")
        let result = await run(terminal)
        #expect(!result.isComplete && terminal.sent.isEmpty)
        #expect(result.stopReason?.contains("could not be read") == true)
        #expect(result.stopReason?.contains("unknown command: herdr") == true)
    }

    @Test func aReviewScreenBeforeTheLastQuestionStopsAndExplains() async {
        let terminal = FakeFormTerminal(form: FormFixtures.form())
        terminal.beforeRead = { terminal in if terminal.sent.count == 1 { terminal.moveTo(tab: 3) } }   // all tabs answered elsewhere
        let result = await run(terminal)
        #expect(!result.isComplete && result.outcomes[0] == .landed)
        #expect(result.stopReason?.contains("review screen") == true)
    }

    @Test func multiSelectAnswersSelectEveryTickedOptionByItsPaneNumber() async {
        let terminal = FakeFormTerminal(form: FormFixtures.form(multiSelect: [1]))
        let result = await run(terminal, choices: [.options([0]), .options([0, 1]), .options([1])])
        #expect(result.isComplete)
        #expect(terminal.sent[1].choice == .select([1, 2]))
    }

    @Test func otherTextGoesAsTextWithLineBreaksFlattened() async {
        let terminal = FakeFormTerminal(form: FormFixtures.form())
        let result = await run(terminal, choices: [.other("my own\nanswer"), .options([0]), .other("also mine")])
        #expect(result.isComplete)
        #expect(terminal.sent.map(\.choice) == [.text("my own answer"), .select([1]), .text("also mine")])
    }

    @Test func aLabelThePaneDoesNotShowStopsBeforeThatQuestionIsTyped() async {
        var wrong = FormFixtures.form()
        wrong = PendingQuestionForm(toolUseId: wrong.toolUseId, questions: wrong.questions.enumerated().map { position, question in
            position == 1 ? FormQuestion(header: question.header, question: question.question, isMultiSelect: false,
                                         options: [.init(label: "A label that is not there", description: "")] + question.options)
                          : question
        })
        let terminal = FakeFormTerminal(form: FormFixtures.form())
        let result = await FormBatchDriver(
            paneId: "p", form: wrong, choices: [.options([0]), .options([0]), .options([0])], source: terminal,
            timing: timing(), progress: { _, _ in }
        ).run()
        #expect(!result.isComplete && result.outcomes[0] == .landed)
        #expect(result.stopReason?.contains("A label that is not there") == true)
        #expect(terminal.sent.count == 1)
    }

    @Test func aCancelledBatchStopsAtTheNextStepAndSaysItTimedOut() async {
        let terminal = FakeFormTerminal(form: FormFixtures.form())
        var expired = timing()
        expired.budgetSecondsPerQuestion = -1   // the whole budget is already spent
        let result = await run(terminal, timing: expired)
        #expect(!result.isComplete && terminal.sent.isEmpty)
        #expect(result.stopReason?.contains("Timed out") == true)
    }
}

private final class ProgressLog: @unchecked Sendable {
    struct Entry: Equatable {
        let question: Int
        let outcome: FormQuestionOutcome
        init(_ question: Int, _ outcome: FormQuestionOutcome) { self.question = question; self.outcome = outcome }
    }
    private let lock = NSLock()
    private var log: [Entry] = []
    var entries: [Entry] { lock.withLock { log } }
    func add(_ question: Int, _ outcome: FormQuestionOutcome) { lock.withLock { log.append(Entry(question, outcome)) } }
}
