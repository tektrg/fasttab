import Foundation
import Testing
@testable import AgentBar

/// A transcript loader scripted per test: waits for the test, records requests.
private final class ContextFake: @unchecked Sendable {
    private let lock = NSLock()
    private var requestedSessions: [String] = []
    private var pending: [CheckedContinuation<SessionContext, Never>] = []

    var requests: [String] { lock.withLock { requestedSessions } }
    var pendingCount: Int { lock.withLock { pending.count } }

    func load(sessionId: String) async -> SessionContext {
        await withCheckedContinuation { continuation in
            lock.withLock {
                requestedSessions.append(sessionId)
                pending.append(continuation)
            }
        }
    }

    func reply(_ context: SessionContext) {
        let continuation = lock.withLock { pending.isEmpty ? nil : pending.removeFirst() }
        continuation?.resume(returning: context)
    }
}

@MainActor
struct AnswerCardModelTests {
    typealias A = AnswerFixtures

    private final class Recorder {
        var notices: [String] = []
        var answeredAgents: [String] = []
        var openedFiles: [URL] = []
    }

    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_000)
    }

    private struct Rig {
        let clock: Clock
        let model: AnswerCardModel
        let source: AnswerFakeSource
        let context: ContextFake
        let recorder: Recorder
    }

    private func makeRig(expiry: TimeInterval = AnswerSendTracker.expirySeconds) -> Rig {
        let context = ContextFake()
        let recorder = Recorder()
        let clock = Clock()
        let model = AnswerCardModel(
            now: { clock.now },
            sendExpirySeconds: expiry,
            loadSessionContext: { await context.load(sessionId: $0) },
            openFile: { recorder.openedFiles.append($0) }
        )
        let source = AnswerFakeSource()
        model.statusSource = source
        model.onNotice = { recorder.notices.append($0) }
        model.onAnswered = { recorder.answeredAgents.append($0) }
        return Rig(clock: clock, model: model, source: source, context: context, recorder: recorder)
    }

    private let fruit = A.question()

    private func agent(_ question: AnswerableQuestion? = nil, sessionId: String? = "session-1") -> AgentSnapshot {
        A.blockedAgent("a", blocker: .question(question ?? fruit), sessionId: sessionId)
    }

    // MARK: - Opening

    @Test func opensOnAnAnswerableQuestionAndReadsTheTranscript() async {
        let rig = makeRig()
        #expect(rig.model.open(agent()))
        #expect(rig.model.card?.label == "agent a")
        #expect(rig.model.card?.message == .loading)
        await waitUntil { rig.context.requests == ["session-1"] }
        #expect(rig.context.requests == ["session-1"])
    }

    @Test func refusesToOpenOnAnythingItCannotAnswer() {
        let rig = makeRig()
        #expect(!rig.model.open(A.blockedAgent("p", blocker: .permission)))
        #expect(!rig.model.open(A.blockedAgent("q", blocker: .questionNotAnswerable)))
        #expect(!rig.model.open(A.blockedAgent("g", blocker: nil)))
        #expect(!rig.model.open(A.blockedAgent("k", blocker: .question(fruit), section: .parked)))
        #expect(rig.model.card == nil)
    }

    @Test func withoutADashboardItSaysSoAndStaysClosed() {
        let rig = makeRig()
        rig.model.statusSource = nil
        #expect(!rig.model.open(agent()))
        #expect(rig.recorder.notices == [AnswerCardModel.noSourceMessage])
    }

    // MARK: - The latest message

    @Test func theTranscriptMessageAndPlanFileFillTheCard() async {
        let rig = makeRig()
        rig.model.open(agent())
        await waitUntil { rig.context.pendingCount == 1 }
        let plan = URL(fileURLWithPath: "/repo/plan.md")
        rig.context.reply(SessionContext(latestMessage: "Here is my plan.", planFile: plan))
        await waitUntil { rig.model.card?.message != .loading }
        #expect(rig.model.card?.message == .text("Here is my plan."))
        #expect(rig.model.card?.planFile == plan)
        rig.model.openPlan()
        #expect(rig.recorder.openedFiles == [plan])
    }

    @Test func withoutATranscriptTheDashboardsContextIsTheFallbackElseNothing() async {
        let rig = makeRig()
        rig.model.open(agent())
        await waitUntil { rig.context.pendingCount == 1 }
        rig.context.reply(.empty)
        await waitUntil { rig.model.card?.message != .loading }
        #expect(rig.model.card?.message == .text("Some prose above the box."))
        rig.model.close()
        rig.model.open(agent(A.question(context: nil)))
        await waitUntil { rig.context.pendingCount == 1 }
        rig.context.reply(.empty)
        await waitUntil { rig.model.card?.message != .loading }
        #expect(rig.model.card?.message == Optional(AnswerCard.Message.none))
        #expect(rig.model.card?.planFile == nil)
    }

    @Test func anAgentWithoutASessionReadsNothingAndNeverShowsLoading() async {
        let rig = makeRig()
        rig.model.open(agent(sessionId: nil))
        await settleTasks()
        #expect(rig.context.requests.isEmpty)
        #expect(rig.model.card?.message == .text("Some prose above the box."))
    }

    @Test func aTranscriptResultForAClosedCardIsDropped() async {
        let rig = makeRig()
        rig.model.open(agent())
        await waitUntil { rig.context.pendingCount == 1 }
        rig.model.close()
        rig.context.reply(SessionContext(latestMessage: "late", planFile: nil))
        await settleTasks()
        #expect(rig.model.card == nil)
    }

    @Test func aTranscriptResultForAnEarlierCardNeverLandsOnALaterOne() async {
        let rig = makeRig()
        rig.model.open(agent())
        await waitUntil { rig.context.pendingCount == 1 }
        rig.model.close()
        rig.model.open(A.blockedAgent("b", blocker: .question(fruit), sessionId: "session-2"))
        await waitUntil { rig.context.pendingCount == 2 }
        rig.context.reply(SessionContext(latestMessage: "for the first card", planFile: nil))   // oldest request
        await settleTasks()
        #expect(rig.model.card?.message == .loading)
        rig.context.reply(SessionContext(latestMessage: "for the second card", planFile: nil))
        await waitUntil { rig.model.card?.message != .loading }
        #expect(rig.model.card?.message == .text("for the second card"))
    }

    // MARK: - Answering

    @Test func aDigitSendsExactlyOneAnswerForTheQuestionOnScreenAndClosesTheCardAtOnce() async {
        let rig = makeRig()
        let blocked = agent()
        rig.model.open(blocked)
        rig.model.handle(.digit(2))
        #expect(rig.model.card == nil)                 // back on the list straight away
        #expect(rig.model.isAwaiting(blocked))         // the row shows Sending answer…
        await rig.source.waitForRequests(1)
        #expect(rig.source.sent == [.init(paneId: "w1:a", choice: .select([2]), question: fruit.identity)])
        #expect(!rig.model.open(blocked))              // no second answer while one is on its way
        await settleTasks()
        #expect(rig.source.sent.count == 1)
    }

    @Test func otherRowsStayUsableWhileOneAnswerIsOnItsWay() async {
        let rig = makeRig()
        rig.model.open(agent())
        rig.model.handle(.digit(1))
        await rig.source.waitForRequests(1)
        let other = A.blockedAgent("b", blocker: .question(A.question(title: "Colour", question: "Which colour?")))
        #expect(!rig.model.isAwaiting(other))
        #expect(rig.model.open(other))
        #expect(rig.model.card?.agentID == "b")
    }

    @Test func successWithNothingNextTellsTheHostAndTheRowKeepsSpinningUntilTheDashboardMovesOn() async {
        let rig = makeRig()
        rig.model.open(agent())
        rig.model.handle(.digit(1))
        await rig.source.waitForRequests(1)
        rig.source.reply(.sent(next: nil))
        await waitUntil { !rig.recorder.answeredAgents.isEmpty }
        #expect(rig.recorder.answeredAgents == ["a"])
        // The dashboard still lists the old question (its sweep lags): the row is still "sending".
        rig.model.reconcile(with: [agent()])
        #expect(rig.model.isAwaiting(agent()))
        #expect(!rig.model.open(agent()))
        // It stops spinning once the dashboard shows something else, or nothing.
        rig.model.reconcile(with: [A.blockedAgent("a", blocker: nil)])
        #expect(!rig.model.isAwaiting(agent()))
    }

    @Test func theSpinnerNeverOutlastsTheExpiryWhenTheDashboardNeverMovesOn() async {
        let rig = makeRig()
        rig.model.open(agent())
        rig.model.handle(.digit(1))
        await rig.source.waitForRequests(1)
        rig.source.reply(.sent(next: nil))
        await waitUntil { !rig.recorder.answeredAgents.isEmpty }
        #expect(rig.model.isAwaiting(agent()))
        rig.clock.now += AnswerSendTracker.expirySeconds + 1
        #expect(!rig.model.isAwaiting(agent()))
    }

    @Test func successWithANextQuestionGivesTheRowItsAnswerButtonBackAndOpensNothingByItself() async {
        let rig = makeRig()
        let second = A.question(title: "Colour", question: "Which colour?", multi: true, labels: ["Red", "Blue"])
        rig.model.open(agent())
        rig.model.handle(.digit(1))
        await rig.source.waitForRequests(1)
        rig.source.reply(.sent(next: second))
        await waitUntil { rig.model.isAwaiting(agent()) == false }
        #expect(rig.model.card == nil)                 // the user asked to land on the list
        #expect(rig.recorder.answeredAgents.isEmpty)   // not finished yet
        // The dashboard still shows the first question; opening gives the next one.
        rig.model.reconcile(with: [agent()])
        #expect(rig.model.open(agent()))
        #expect(rig.model.card?.state.question == second)
        rig.model.handle(.digit(2))
        rig.model.handle(.enter)
        await rig.source.waitForRequests(1)
        #expect(rig.source.sent.last?.question == second.identity)
        #expect(rig.source.sent.last?.choice == .select([2]))
    }

    @Test func theQuestionIsSentAsThePaneReadsItWhenItIsTheSameQuestionCutDifferently() async {
        let rig = makeRig()
        let feedCopy = A.question(question: "Should we ship it, and a lso test it?")
        let rule = String(repeating: "─", count: 60)
        rig.source.screen = .screen(lines: [rule, "  ☐ Fruit", "Should we ship it, and also test it?", "  ❯ 1. Apple", "    2. Banana", "    3. Type something.", rule], readAt: Date())
        rig.model.open(agent(feedCopy))
        rig.model.handle(.digit(1))
        await rig.source.waitForRequests(1)
        #expect(rig.source.sent.last?.question == QuestionIdentity(title: "Fruit", question: "Should we ship it, and also test it?"))
    }

    @Test func aDifferentQuestionOnThePaneIsNeverSubstitutedForTheOneShown() async {
        let rig = makeRig()
        let rule = String(repeating: "─", count: 60)
        rig.source.screen = .screen(lines: [rule, "  ☐ Fruit", "A totally different question?", "  ❯ 1. Apple", "    2. Banana", rule], readAt: Date())
        rig.model.open(agent())
        rig.model.handle(.digit(1))
        await rig.source.waitForRequests(1)
        #expect(rig.source.sent.last?.question == fruit.identity)
    }

    @Test func anUnreadablePaneFallsBackToTheQuestionShown() async {
        let rig = makeRig()
        rig.source.screen = .failure("pane wedged")
        rig.model.open(agent())
        rig.model.handle(.digit(1))
        await rig.source.waitForRequests(1)
        #expect(rig.source.sent.last?.question == fruit.identity)
    }

    @Test func aRefusalFreesTheRowShowsTheDashboardsWordsInTheFooterAndNeverRetries() async {
        let rig = makeRig()
        rig.model.open(agent())
        rig.model.handle(.digit(1))
        await rig.source.waitForRequests(1)
        rig.source.reply(.failed("question changed or gone — re-check the pane"))
        await waitUntil { !rig.recorder.notices.isEmpty }
        #expect(rig.recorder.notices == ["Answer not sent: question changed or gone — re-check the pane"])
        #expect(!rig.model.isAwaiting(agent()))
        #expect(rig.model.card == nil)
        #expect(rig.recorder.answeredAgents.isEmpty)
        await settleTasks()
        #expect(rig.source.sent.count == 1)
    }

    @Test func afterARefusalReopeningBringsBackWhatWasTypedAndTicked() async {
        let rig = makeRig()
        rig.model.open(agent(A.question(multi: true, labels: ["Red", "Green"])))
        rig.model.handle(.digit(3))               // the free-text row
        rig.model.setOtherText("my own idea")
        rig.model.handle(.enter)
        await rig.source.waitForRequests(1)
        rig.source.reply(.failed("typed text did not land — re-check the pane"))
        await waitUntil { !rig.recorder.notices.isEmpty }
        let retry = agent(A.question(multi: true, labels: ["Red", "Green"]))
        #expect(rig.model.open(retry))
        #expect(rig.model.card?.state.otherText == "my own idea")
        rig.model.handle(.enter)                  // Enter on the Other row opens the field with the text ready
        #expect(rig.model.card?.state.readyChoice == .text("my own idea"))
    }

    @Test func aRowThatNeverGetsAReplyIsFreedWithAWarningAfterTheExpiry() async {
        let rig = makeRig(expiry: 0.4)
        rig.model.open(agent())
        rig.model.handle(.digit(1))
        #expect(rig.model.isAwaiting(agent()))
        await waitUntil { !rig.model.isAwaiting(agent()) }
        #expect(!rig.model.isAwaiting(agent()))
        #expect(rig.recorder.notices == [AnswerCardModel.noReplyMessage])
    }

    @Test func aRefusalStillReportsWhenTheRowLeftTheListMeanwhile() async {
        let rig = makeRig()
        rig.model.open(agent())
        rig.model.handle(.digit(1))
        await rig.source.waitForRequests(1)
        rig.model.reconcile(with: [])   // a feed outage or a filter: the row is not drawn, the answer is still on its way
        rig.source.reply(.failed("pane gone"))
        await waitUntil { !rig.recorder.notices.isEmpty }
        #expect(rig.recorder.notices == ["Answer not sent: pane gone"])
    }

    @Test func resettingForAnotherDashboardForgetsInFlightAnswers() async {
        let rig = makeRig()
        rig.model.open(agent())
        rig.model.handle(.digit(1))
        await rig.source.waitForRequests(1)
        rig.model.reset()
        #expect(!rig.model.isAwaiting(agent()))
        rig.source.reply(.sent(next: nil))
        await settleTasks()
        #expect(rig.recorder.answeredAgents.isEmpty)
    }

    @Test func typedTextIsSentAsATextChoice() async {
        let rig = makeRig()
        rig.model.open(agent())
        rig.model.handle(.digit(3))
        rig.model.setOtherText("  my own idea ")
        rig.model.handle(.enter)
        await rig.source.waitForRequests(1)
        #expect(rig.source.sent.first?.choice == .text("my own idea"))
    }

    // MARK: - Following the dashboard

    @Test func aQuestionAnsweredCannotBeReopenedWhileTheDashboardStillShowsItAndOnceItMovedOnItCanBeAnsweredAgain() async {
        let rig = makeRig()
        rig.model.open(agent())
        rig.model.handle(.digit(1))
        await rig.source.waitForRequests(1)
        rig.source.reply(.sent(next: nil))
        await waitUntil { !rig.recorder.answeredAgents.isEmpty }
        rig.model.reconcile(with: [agent()])
        #expect(!rig.model.open(agent()))
        rig.model.reconcile(with: [agent(A.question(title: "Colour", question: "Which colour?"))])
        #expect(rig.model.open(agent(A.question(title: "Colour", question: "Which colour?"))))
    }

    @Test func aDifferentQuestionReplacesTheCardAndDropsTheOldChoice() async {
        let rig = makeRig()
        rig.model.open(agent(A.question(multi: true, labels: ["Red", "Green"])))
        rig.model.handle(.digit(1))
        await waitUntil { rig.context.pendingCount == 1 }
        let other = A.question(title: "Size", question: "Which size?")
        rig.model.reconcile(with: [agent(other)])
        #expect(rig.model.card?.state.question == other)
        #expect(rig.model.card?.state.checkedIndices.isEmpty == true)
        #expect(rig.model.card?.message == .loading)   // the new turn's message is read again
        await waitUntil { rig.context.requests.count == 2 }
        #expect(rig.context.requests.count == 2)
    }

    @Test func theSameQuestionInAnUpdateKeepsTheUsersProgress() async {
        let rig = makeRig()
        let question = A.question(multi: true, labels: ["Red", "Green"])
        rig.model.open(agent(question))
        rig.model.handle(.digit(2))
        await waitUntil { rig.context.pendingCount == 1 }
        rig.model.reconcile(with: [agent(question)])
        #expect(rig.model.card?.state.checkedIndices == [2])
        await settleTasks()
        #expect(rig.context.requests.count == 1)
    }

    @Test func theCardStaysWhileTheViewFlapsBetweenReadingsAndClosesWhenTheAgentIsNoLongerBlocked() {
        let rig = makeRig()
        rig.model.open(agent())
        rig.model.reconcile(with: [A.blockedAgent("a", blocker: .questionLoading(fruit.identity))])
        rig.model.reconcile(with: [A.blockedAgent("a", blocker: .questionNotAnswerable)])
        rig.model.reconcile(with: [agent()])
        #expect(rig.model.isOpen)
        rig.model.reconcile(with: [A.blockedAgent("a", blocker: nil)])
        #expect(rig.model.card == nil)
        #expect(rig.recorder.notices.isEmpty)
    }
}
