import Foundation
import Testing
@testable import AgentBar

/// The answer card as the panel drives it: rows, keys, selection and the
/// footer, against a fake dashboard. Nothing here touches a real one.
@MainActor
struct AnswerPanelModelTests {
    typealias A = AnswerFixtures
    typealias F = AgentListFixtures

    @MainActor final class ActivationLog { var agentIDs: [String] = [] }

    private let fruit = A.question()

    private func makeRig(_ agents: [AgentSnapshot]) -> (model: AgentPanelModel, source: AnswerFakeSource, activations: ActivationLog) {
        let defaults = makeScratchDefaults("answer-panel")
        let answer = AnswerCardModel(loadSessionContext: { _ in .empty }, openFile: { _ in })
        let model = AgentPanelModel(
            store: FrecencyStore(defaults: defaults),
            triageStore: TriageStore(defaults: defaults),
            answer: answer,
            now: { F.now }
        )
        let source = AnswerFakeSource()
        model.statusSource = source
        let activations = ActivationLog()
        model.onActivate = { activations.agentIDs.append($0.id) }
        model.receive(F.snapshot(agents))
        return (model, source, activations)
    }

    private var blockedQuestion: AgentSnapshot { A.blockedAgent("q", blocker: .question(fruit)) }

    // MARK: - Opening from the row

    @Test func aBlockedQuestionSortsFirstAndItsAnswerButtonOpensTheCard() {
        let (model, _, _) = makeRig([F.agent("finished"), blockedQuestion])
        #expect(model.presentation.agents.map(\.id) == ["q", "finished"])
        #expect(model.selectedAgentID == "q")
        model.press(.answer, on: "q")
        #expect(model.answer.card?.agentID == "q")
    }

    @Test func theAnswerButtonStaysWhileTheDashboardFlapsBetweenReportsOfTheSameQuestion() {
        let (model, _, _) = makeRig([blockedQuestion])
        model.receive(F.snapshot([A.blockedAgent("q", blocker: .questionLoading(fruit.identity))]))
        #expect(model.presentation.agents.first?.blockedOnYou == .question(fruit))
        model.receive(F.snapshot([A.blockedAgent("q", blocker: .permission)]))
        #expect(model.presentation.agents.first?.blockedOnYou == .question(fruit))
        model.press(.answer, on: "q")
        #expect(model.answer.card?.agentID == "q")
    }

    @Test func aRowThatWasNeverAnswerableShowsAReadingAnswerAndPressingItOpensNothing() {
        let (model, _, _) = makeRig([A.blockedAgent("l", blocker: .questionLoading(nil))])
        model.press(.answer, on: "l")
        #expect(!model.answer.isOpen)
    }

    @Test func rightArrowThenEnterOpensTheCardFromTheKeyboard() {
        let (model, _, _) = makeRig([blockedQuestion])
        #expect(model.moveButtonHighlight(by: 1))
        #expect(model.highlightedButton == .answer)
        model.activateSelected()
        #expect(model.answer.isOpen)
    }

    @Test func theArrowsOnlyReachTheButtonsWithAnEmptySearch() {
        let (model, _, _) = makeRig([blockedQuestion])
        model.query = "q"
        #expect(!model.moveButtonHighlight(by: 1))   // the text field keeps its caret keys
        #expect(model.highlightedButton == nil)
    }

    @Test func aPermissionRowsOpenTerminalSwitchesToTheAgentAndOpensNoCard() {
        let (model, _, activations) = makeRig([A.blockedAgent("p", blocker: .permission)])
        model.press(.openTerminal, on: "p")
        #expect(activations.agentIDs == ["p"])
        #expect(!model.answer.isOpen)
    }

    @Test func anUnansweredRowCannotOpenACardEvenIfAskedTo() {
        let (model, _, _) = makeRig([A.blockedAgent("u", blocker: .questionNotAnswerable)])
        model.press(.answer, on: "u")   // not one of its buttons
        #expect(!model.answer.isOpen)
    }

    // MARK: - Keys reach the card, not the list

    @Test func whileTheCardIsOpenTheKeysDriveTheCard() async {
        let (model, source, activations) = makeRig([blockedQuestion, F.agent("other")])
        model.press(.answer, on: "q")
        model.moveSelectionOrAnswerHighlight(by: 1)
        #expect(model.answer.card?.state.highlightedPosition == 1)
        #expect(model.selectedAgentID == "q")           // the list selection did not move
        #expect(model.moveButtonHighlight(by: 1))       // swallowed: no row buttons under the card
        model.activateSelected()                        // Enter sends the highlighted option
        await source.waitForRequests(1)
        #expect(source.sent.first?.choice == .select([2]))
        #expect(activations.agentIDs.isEmpty)           // Enter did not switch to the agent
    }

    @Test func spaceTicksInsteadOfPeekingAndEscGoesBackToTheList() {
        let (model, _, _) = makeRig([A.blockedAgent("m", blocker: .question(A.question(multi: true, labels: ["Red", "Green"])))])
        model.press(.answer, on: "m")
        #expect(model.togglePeek())
        #expect(model.answer.card?.state.checkedIndices == [1])
        #expect(model.peek == nil)
        #expect(model.backOutOfButtons())
        #expect(!model.answer.isOpen)
        #expect(!model.backOutOfButtons())   // now Esc closes the panel as usual
    }

    @Test func sendingClosesTheCardAtOnceAndLeavesTheSelectionOnThatRow() async {
        let (model, source, _) = makeRig([blockedQuestion, A.blockedAgent("r", blocker: .permission)])
        model.press(.answer, on: "q")
        model.answer.handle(.digit(1))
        #expect(!model.answer.isOpen)
        #expect(model.selectedAgentID == "q")
        #expect(model.answer.isAwaiting(blockedQuestion))
        await source.waitForRequests(1)
        #expect(!model.backOutOfButtons())   // Esc is the panel's again, not swallowed by a card
    }

    @Test func aRowWhoseAnswerIsOnItsWayHasNoUsableButtonsAndTheOtherRowsKeepTheirs() async {
        let (model, source, _) = makeRig([blockedQuestion, A.blockedAgent("r", blocker: .permission)])
        model.press(.answer, on: "q")
        model.answer.handle(.digit(1))
        await source.waitForRequests(1)
        model.press(.park, on: "q")
        model.press(.answer, on: "q")
        #expect(!model.answer.isOpen)
        #expect(model.presentation.agents.contains { $0.id == "q" })   // not parked
        #expect(model.moveButtonHighlight(by: 1))
        #expect(model.highlightedButton == nil)
        model.select(agentID: "r")
        #expect(model.moveButtonHighlight(by: 1))
        #expect(model.highlightedButton == .openTerminal)
    }

    // MARK: - After the answer

    @Test func answeringTheLastQuestionMovesOnToTheNextNeedsYouRow() async {
        let (model, source, _) = makeRig([blockedQuestion, A.blockedAgent("r", blocker: .permission), F.agent("busy", section: .working)])
        model.press(.answer, on: "q")
        model.answer.handle(.digit(1))
        await source.waitForRequests(1)
        source.reply(.sent(next: nil))
        await waitUntil { model.selectedAgentID == "r" }
        #expect(model.selectedAgentID == "r")
        #expect(!model.answer.isOpen)
    }

    @Test func aMultiQuestionFormReturnsToTheListWithTheAnswerButtonAndTheSelectionStays() async {
        let (model, source, _) = makeRig([blockedQuestion, A.blockedAgent("r", blocker: .permission)])
        let second = A.question(title: "Colour", question: "Which colour?")
        model.press(.answer, on: "q")
        model.answer.handle(.digit(1))
        await source.waitForRequests(1)
        source.reply(.sent(next: second))
        await waitUntil { !model.answer.isAwaiting(blockedQuestion) }
        #expect(!model.answer.isOpen)
        #expect(model.selectedAgentID == "q")
        model.press(.answer, on: "q")
        #expect(model.answer.card?.state.question == second)
    }

    @Test func aRefusalShowsVerbatimInTheFooterForLongEnoughToRead() async {
        let (model, source, _) = makeRig([blockedQuestion])
        model.press(.answer, on: "q")
        model.answer.handle(.digit(1))
        await source.waitForRequests(1)
        source.reply(.failed("question changed or gone — re-check the pane"))
        await waitUntil { model.footerNotice != nil }
        #expect(model.footerNotice == .actionFailed("Answer not sent: question changed or gone — re-check the pane"))
        #expect(!model.answer.isAwaiting(blockedQuestion))
        #expect(AgentPanelModel.answerNoticeSeconds >= 8)
    }

    @Test func aRefusalThatArrivedWhileThePanelWasAwayIsShownOnceOnTheNextSummon() async {
        let (model, source, _) = makeRig([blockedQuestion])
        model.press(.answer, on: "q")
        model.answer.handle(.digit(1))
        await source.waitForRequests(1)
        source.reply(.failed("pane gone"))
        await waitUntil { model.footerNotice != nil }
        model.resetForShow()   // the panel was hidden and is summoned again
        #expect(model.footerNotice == .actionFailed("Answer not sent: pane gone"))
        model.resetForShow()
        #expect(model.footerNotice == nil)
    }

    // MARK: - Status updates while open

    @Test func theQuestionGoingAwayInAnUpdateBringsBackTheList() {
        let (model, _, _) = makeRig([blockedQuestion])
        model.press(.answer, on: "q")
        model.receive(F.snapshot([F.agent("q")]))   // answered from the terminal
        #expect(!model.answer.isOpen)
    }

    @Test func aFilteredOutAgentDoesNotCloseTheCard() {
        let (model, _, _) = makeRig([blockedQuestion, F.agent("other", label: "zzz")])
        model.press(.answer, on: "q")
        model.receive(F.snapshot([blockedQuestion, F.agent("other", label: "zzz")]))
        #expect(model.answer.isOpen)
    }

    @Test func aDeadFeedClosesTheCardRatherThanLeavingItAnsweringIntoTheDark() {
        let (model, _, _) = makeRig([blockedQuestion])
        model.press(.answer, on: "q")
        model.receive(.down(reason: "Status feed down", at: F.now))
        #expect(!model.answer.isOpen)
    }

    @Test func aFreshSummonStartsOnTheListAndAnInFlightAnswerIsNotAbandoned() async {
        let (model, source, _) = makeRig([blockedQuestion])
        model.press(.answer, on: "q")
        model.resetForShow()
        #expect(!model.answer.isOpen)

        model.press(.answer, on: "q")
        model.answer.handle(.digit(1))
        await source.waitForRequests(1)
        model.resetForShow()
        #expect(model.answer.isAwaiting(blockedQuestion))
        source.reply(.sent(next: nil))
        await waitUntil { model.selectedAgentID != nil && !model.answer.isAwaiting(A.blockedAgent("q", blocker: nil)) }
        #expect(source.sent.count == 1)
    }

    @Test func cyclingToAnotherAgentLeavesTheCard() {
        let (model, _, _) = makeRig([blockedQuestion, F.agent("other")])
        model.press(.answer, on: "q")
        model.moveSelection(by: 1)   // the alt-tab cycle
        #expect(!model.answer.isOpen)
        #expect(model.selectedAgentID == "other")
    }

    @Test func theCardIsPartOfTheFooterHints() {
        let (model, _, _) = makeRig([blockedQuestion])
        #expect(model.answer.card?.state.hintMode == nil)
        model.press(.answer, on: "q")
        #expect(model.answer.card?.state.hintMode == .singleSelect)
    }
}
