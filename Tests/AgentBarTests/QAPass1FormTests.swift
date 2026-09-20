import Foundation
import Testing
@testable import AgentBar

/// QA pass 1 (anything that types into a real agent): defects found in the multi-question form send.
struct QAPass1FormPlannerTests {
    private func pane(_ labels: [String]) -> AnswerableQuestion {
        var options = labels.enumerated().map { AnswerableQuestion.Option(index: $0.offset + 1, label: $0.element, description: "", isOther: false) }
        options.append(.init(index: labels.count + 1, label: "Type something.", description: "", isOther: true))
        return AnswerableQuestion(title: "T", question: "Q?", isMultiSelect: false, options: options, context: nil)
    }

    private func question(_ labels: [String], multi: Bool = false) -> FormQuestion {
        FormQuestion(header: "H", question: "Q?", isMultiSelect: multi, options: labels.map { .init(label: $0, description: "") })
    }

    /// "Yes" is the start of "Yes, and remember": the first pane row whose text merely starts the same way
    /// must not win over the row that is exactly the chosen label.
    @Test func aLabelThatStartsAnotherLabelPicksItsOwnRowNotTheFirstPrefixMatch() throws {
        let labels = ["Yes", "Yes, and remember"]
        let choice = FormBatchPlanner.answerChoice(for: .options([1]), question: question(labels), pane: pane(labels))
        #expect(try choice.get() == .select([2]))
        let plain = FormBatchPlanner.answerChoice(for: .options([0]), question: question(labels), pane: pane(labels))
        #expect(try plain.get() == .select([1]))
    }

    /// Ticking both of two such options must tick two different rows (a duplicate digit would untick the first).
    @Test func tickingTwoLabelsWhereOneStartsTheOtherTicksTwoDifferentRows() throws {
        let labels = ["React", "React Native"]
        let choice = FormBatchPlanner.answerChoice(for: .options([0, 1]), question: question(labels, multi: true), pane: pane(labels))
        #expect(try choice.get() == .select([1, 2]))
    }

    /// A label the pane cut short still matches, as long as only one row could be meant.
    @Test func aLabelCutShortByThePaneWidthStillMatchesItsOnlyCandidate() throws {
        let choice = FormBatchPlanner.answerChoice(
            for: .options([1]), question: question(["Apple", "Bananas are yellow and long"]), pane: pane(["Apple", "Bananas are yel"])
        )
        #expect(try choice.get() == .select([2]))
    }

    /// Two rows that both could be the cut-short label: nothing is guessed.
    @Test func anAmbiguousCutShortLabelIsRefusedNotGuessed() {
        let choice = FormBatchPlanner.answerChoice(
            for: .options([0]), question: question(["Deploy to staging now", "Other"]), pane: pane(["Deploy to", "Deploy to s"])
        )
        if case .success(let built) = choice { Issue.record("should not guess, built \(built)") }
    }
}

/// Two forms sent at once (two agents) must each stay cancellable and time-boxed on their own.
@MainActor
struct QAPass1FormBatchLifetimeTests {
    /// Sends each pane's calls to its own fake terminal.
    private final class RoutingSource: AgentStatusSource, @unchecked Sendable {
        let updates = AsyncStream<StatusSnapshot> { _ in }
        let terminals: [String: FakeFormTerminal]
        init(_ terminals: [String: FakeFormTerminal]) { self.terminals = terminals }
        func focus(paneId: String) async -> FocusResult { .success }
        func perform(_ kind: SessionActionKind, rowId: String, confirmed: Bool) async -> SessionActionOutcome { .failed("unused") }
        func paneScreen(paneId: String) async -> PaneScreenResult { await terminals[paneId]!.paneScreen(paneId: paneId) }
        func answer(paneId: String, choice: AnswerChoice, question: QuestionIdentity) async -> AnswerResult {
            await terminals[paneId]!.answer(paneId: paneId, choice: choice, question: question)
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func next() -> Int { lock.withLock { defer { count += 1 }; return count } }
        var value: Int { lock.withLock { count } }
    }

    @Test func aFinishedBatchNeverDisarmsTheCancellationOfAnotherAgentsRunningBatch() async {
        let form = FormFixtures.form()
        let terminalA = FakeFormTerminal(form: form), terminalB = FakeFormTerminal(form: form)
        let gateA = AsyncGate(), gateB = AsyncGate(), calls = Counter()
        // The first answer of each batch is held: A's is call 0, B's is call 1.
        let hold: @Sendable (Int) async -> Void = { _ in
            switch calls.next() {
            case 0: await gateA.wait()
            case 1: await gateB.wait()
            default: break
            }
        }
        terminalA.beforeAnswer = hold
        terminalB.beforeAnswer = hold

        var timing = FormBatchTiming()
        timing.pause = { _ in }
        var answered: [String] = []
        let model = AnswerCardModel(loadSessionContext: { _ in .empty }, loadPendingForm: { _ in form }, formTiming: timing)
        model.statusSource = RoutingSource(["w1:a": terminalA, "w1:b": terminalB])
        model.onAnswered = { answered.append($0) }

        func agent(_ id: String) -> AgentSnapshot {
            let question = PaneQuestionReader.question(in: FormFixtures.screen(form, tab: 0))!
            return AnswerFixtures.blockedAgent(id, blocker: .question(question))
        }
        for (position, id) in ["a", "b"].enumerated() {
            #expect(model.open(agent(id)))
            await waitUntil { model.card?.form != nil }
            for question in 0..<form.questions.count { model.clickFormRow(0, of: question) }
            model.pressSend()
            await waitUntil { calls.value > position }   // this batch's first answer is being held
        }

        gateA.open()
        await waitUntil { answered.contains("a") }
        #expect(answered == ["a"])   // A is done; B is still held at its first answer

        // The dashboard changed: everything running must be told to stop. B may finish the answer it is on, no more.
        model.reset()
        gateB.open()
        await settleTasks()
        await settleTasks()
        #expect(terminalB.sent.count <= 1, "B kept sending after reset: \(terminalB.sent.count) answers")
    }
}
