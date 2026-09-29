import Foundation
import Testing
@testable import AgentBar

/// A status source that answers stop/close from a script, plain-`.sent`s every message
/// (Compact/Clear), and records every call of both kinds.
private final class ActionFakeSource: AgentStatusSource, @unchecked Sendable {
    struct Call: Equatable {
        let kind: SessionActionKind
        let rowId: String
        let confirmed: Bool
    }

    struct SentMessage: Equatable {
        let rowId: String
        let text: String
        let confirmed: Bool
    }

    let updates = AsyncStream<StatusSnapshot> { _ in }
    private let lock = NSLock()
    private var recorded: [Call] = []
    private var sentMessages: [SentMessage] = []
    private var script: [SessionActionOutcome]

    init(script: [SessionActionOutcome] = []) { self.script = script }

    var calls: [Call] { lock.withLock { recorded } }
    var messagesSent: [SentMessage] { lock.withLock { sentMessages } }

    func focus(paneId: String) async -> FocusResult { .success }
    /// A clean prompt, no open picker: the pre-send pane guard `MessageCardModel.sendDirect` does
    /// before every send (including Compact/Clear) always finds nothing in its way.
    func paneScreen(paneId: String) async -> PaneScreenResult { .screen(lines: ["⏺ Done.", "", "❯ "], readAt: Date()) }

    func answer(paneId: String, choice: AnswerChoice, question: QuestionIdentity) async -> AnswerResult { .failed("unused") }
    func perform(_ kind: SessionActionKind, rowId: String, confirmed: Bool) async -> SessionActionOutcome {
        lock.withLock {
            recorded.append(Call(kind: kind, rowId: rowId, confirmed: confirmed))
            return script.isEmpty ? .failed("script ran out") : script.removeFirst()
        }
    }
    func sendMessage(rowId: String, text: String, confirmed: Bool) async -> MessageSendOutcome {
        lock.withLock { sentMessages.append(SentMessage(rowId: rowId, text: text, confirmed: confirmed)) }
        return .sent(queued: false)
    }
}

@MainActor
struct RowActionsModelTests {
    typealias F = AgentListFixtures

    private func makeModel(script: [SessionActionOutcome] = [], holdSeconds: TimeInterval = 60) -> (AgentPanelModel, ActionFakeSource, UserDefaults) {
        let defaults = makeScratchDefaults("row-actions")
        let model = AgentPanelModel(
            store: FrecencyStore(defaults: defaults),
            triageStore: TriageStore(defaults: defaults),
            completedHoldSeconds: holdSeconds,
            now: { F.now }
        )
        let source = ActionFakeSource(script: script)
        model.statusSource = source
        return (model, source, defaults)
    }

    private func agents(_ ids: [String], section: AgentSection = .needsYou) -> [AgentSnapshot] {
        ids.map { F.agent($0, section: section) }
    }

    private let stoppedRow = F.agent("a", label: "alpha", section: .ended, canFocus: true, actions: AgentActions(stop: .unavailable, close: .unknown))

    // MARK: - Park

    @Test func parkMovesTheRowToParkedAndCarriesOnToTheNextRow() {
        let (model, source, _) = makeModel()
        model.receive(F.snapshot(agents(["a", "b", "c"])))
        model.press(.park, on: "a")
        #expect(model.presentation.agents.map(\.section) == [.needsYou, .needsYou, .parked])
        #expect(model.presentation.agents.map(\.id) == ["b", "c", "a"])
        #expect(model.selectedAgentID == "b")
        #expect(source.calls.isEmpty)   // parking is local
    }

    @Test func unparkBringsItBackAndKeepsItSelected() {
        let (model, _, _) = makeModel()
        // No hook data = cannot take Compact, so Park sends nothing and Unpark is not blocked by an in-flight /compact.
        model.receive(F.snapshot(["a", "b"].map { F.agent($0, hasHookData: false) }))
        model.press(.park, on: "a")
        model.select(agentID: "a")
        model.press(.unpark, on: "a")
        #expect(model.presentation.agents.map(\.section) == [.needsYou, .needsYou])
        #expect(model.selectedAgentID == "a")
    }

    @Test func parkedSurvivesARestartThroughItsOwnDefaults() {
        let (model, _, defaults) = makeModel()
        model.receive(F.snapshot(agents(["a", "b"])))
        model.press(.park, on: "a")

        let reopened = AgentPanelModel(store: FrecencyStore(defaults: defaults), triageStore: TriageStore(defaults: defaults), now: { F.now })
        reopened.receive(F.snapshot(agents(["a", "b"])))
        #expect(reopened.presentation.agents.map(\.section) == [.needsYou, .parked])
    }

    @Test func aParkedAgentSeenWorkingComesBackToNeedsYouWhenItFinishes() {
        let (model, _, _) = makeModel()
        model.receive(F.snapshot(agents(["a"])))
        model.press(.park, on: "a")
        #expect(model.presentation.agents.map(\.section) == [.parked])
        model.receive(F.snapshot(agents(["a"], section: .working)))
        #expect(model.presentation.agents.map(\.section) == [.working])
        model.receive(F.snapshot(agents(["a"])))
        #expect(model.presentation.agents.map(\.section) == [.needsYou])
    }

    @Test func aDeadFeedNeitherPrunesNorUnparks() {
        let (model, _, _) = makeModel()
        model.receive(F.snapshot(agents(["a"])))
        model.press(.park, on: "a")
        model.receive(StatusSnapshot.down(reason: "unreachable", at: F.now))
        model.receive(F.snapshot(agents(["a"])))
        #expect(model.presentation.agents.map(\.section) == [.parked])
    }

    // MARK: - Done: stop, confirm, close

    @Test func doneOnAnIdleAgentStopsItInOnePress() async {
        let (model, source, _) = makeModel(script: [.succeeded])
        model.receive(F.snapshot(agents(["a", "b"])))
        await model.press(.done, on: "a")?.value
        #expect(source.calls == [.init(kind: .stop, rowId: "a", confirmed: false)])
        #expect(model.rowActionStates["a"] == .completed(.done))
        #expect(model.selectedAgentID == "b")   // carries on down the list
    }

    @Test func doneNeedingConfirmationTurnsTheButtonIntoAnInlineConfirmThenSendsConfirm() async {
        let (model, source, _) = makeModel(script: [.needsConfirmation(reason: "9 uncommitted files"), .succeeded])
        model.receive(F.snapshot(agents(["a"])))
        await model.press(.done, on: "a")?.value
        #expect(model.rowActionStates["a"] == .confirming(.done, reason: "9 uncommitted files"))
        #expect(source.calls.count == 1)
        await model.press(.done, on: "a")?.value
        #expect(source.calls.last == .init(kind: .stop, rowId: "a", confirmed: true))
        #expect(model.rowActionStates["a"] == .completed(.done))
    }

    @Test func aFailedDoneShowsTheFooterNoticeAndNeverLeavesTheRowStuck() async {
        let (model, _, _) = makeModel(script: [.failed("Can't reach the status dashboard.")])
        model.receive(F.snapshot(agents(["a"])))
        await model.press(.done, on: "a")?.value
        #expect(model.rowActionStates["a"] == nil)
        #expect(model.footerNotice == .actionFailed("Couldn't finish that agent: Can't reach the status dashboard"))
    }

    @Test func aFailedConfirmAlsoClearsTheConfirmState() async {
        let (model, _, _) = makeModel(script: [.needsConfirmation(reason: "x"), .failed("refused: already stopped")])
        model.receive(F.snapshot(agents(["a"])))
        await model.press(.done, on: "a")?.value
        await model.press(.done, on: "a")?.value
        #expect(model.rowActionStates["a"] == nil)
        #expect(model.footerNotice == .actionFailed("Couldn't finish that agent: Already stopped"))
    }

    @Test func aSecondPressWhileTheRequestIsInFlightIsIgnored() async {
        let (model, source, _) = makeModel(script: [.succeeded])
        model.receive(F.snapshot(agents(["a"])))
        let first = model.press(.done, on: "a")
        #expect(model.rowActionStates["a"] == .busy(.done))
        #expect(model.press(.done, on: "a") == nil)
        await first?.value
        #expect(source.calls.count == 1)
    }

    @Test func aRefusedButtonIsNeverSent() {
        let refusal = ActionAvailability(isEnabled: false, needsConfirm: false, reason: "refused: dev-server pane")
        let (model, source, _) = makeModel()
        model.receive(F.snapshot([F.agent("a", actions: AgentActions(stop: refusal, close: refusal))]))
        #expect(model.press(.done, on: "a") == nil)
        #expect(source.calls.isEmpty)
    }

    @Test func withoutAStatusSourceDoneFailsPlainlyInsteadOfDoingNothing() {
        let (model, _, _) = makeModel()
        model.statusSource = nil
        model.receive(F.snapshot(agents(["a"])))
        model.press(.done, on: "a")
        #expect(model.rowActionStates["a"] == nil)
        #expect(model.footerNotice != nil)
    }

    @Test func theStoppedPaneRowOffersClosePaneAndItsRowDisappearsAfterClose() async {
        let (model, source, _) = makeModel(script: [.succeeded])
        model.receive(F.snapshot([stoppedRow]))
        #expect(model.selectedAgentID == "a")   // a pane that is still open can be selected
        await model.press(.closePane, on: "a")?.value
        #expect(source.calls == [.init(kind: .close, rowId: "a", confirmed: false)])
        #expect(model.rowActionStates["a"] == .completed(.closePane))
        model.receive(F.snapshot([]))   // the board no longer lists it
        #expect(model.rowActionStates["a"] == nil)
    }

    @Test func aCompletedDoneClearsOnceTheAgentLeavesTheLiveList() async {
        let (model, _, _) = makeModel(script: [.succeeded])
        model.receive(F.snapshot(agents(["a", "b"])))
        await model.press(.done, on: "a")?.value
        model.receive(F.snapshot(agents(["a", "b"])))   // feed still lagging: agent still listed
        #expect(model.rowActionStates["a"] == .completed(.done))
        model.receive(F.snapshot([stoppedRow] + agents(["b"])))   // now stopped, pane open
        #expect(model.rowActionStates["a"] == nil)
    }

    @Test func aCompletedStateNeverOutstaysALaggingFeed() async {
        let (model, _, _) = makeModel(script: [.succeeded], holdSeconds: 0.01)
        model.receive(F.snapshot(agents(["a"])))
        await model.press(.done, on: "a")?.value
        for _ in 0..<200 where model.rowActionStates["a"] != nil { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(model.rowActionStates["a"] == nil)
    }

    // MARK: - Keyboard

    @Test func arrowsWalkTheButtonsAndEnterPressesTheHighlightedOne() {
        let (model, _, _) = makeModel()
        model.receive(F.snapshot(agents(["a", "b"])))
        #expect(model.moveButtonHighlight(by: 1))
        #expect(model.highlightedButton == .peek)
        #expect(model.moveButtonHighlight(by: 1))
        #expect(model.highlightedButton == .park)
        model.activateSelected()
        #expect(model.presentation.agents.map(\.section) == [.needsYou, .parked])   // Park is local, no round trip
    }

    /// Done/Close pane moved into the ⋯ menu, so they are no longer on the keyboard's list at all
    /// (`RowButtonsTests.moreActionsIsAKeyboardStopAfterTheExistingButtons`); the trigger is
    /// reachable by ←/→ but Enter on it is a deliberate no-op (`RowActionMachine.plan(.moreActions)`
    /// — a native SwiftUI `Menu` cannot be popped open programmatically from here).
    @Test func enterOnTheHighlightedMoreActionsTriggerDoesNotOpenItOrSendAnything() {
        let (model, source, _) = makeModel()
        model.receive(F.snapshot(agents(["a", "b"])))
        model.moveButtonHighlight(by: 1)   // peek
        model.moveButtonHighlight(by: 1)   // park
        model.moveButtonHighlight(by: 1)   // message
        model.moveButtonHighlight(by: 1)   // ⋯
        #expect(model.highlightedButton == .moreActions)
        model.activateSelected()
        #expect(source.calls.isEmpty)
        #expect(model.rowActionStates["a"] == nil)
    }

    @Test func enterWithNoHighlightStillSwitchesToTheAgent() {
        let (model, _, _) = makeModel()
        var activated: [String] = []
        model.onActivate = { activated.append($0.id) }
        model.receive(F.snapshot(agents(["a"])))
        model.activateSelected()
        #expect(activated == ["a"])
    }

    @Test func enterOnAHighlightedParkButtonParksInsteadOfSwitching() {
        let (model, _, _) = makeModel()
        var activated: [String] = []
        model.onActivate = { activated.append($0.id) }
        model.receive(F.snapshot(agents(["a", "b"])))
        model.moveButtonHighlight(by: 1)   // Peek is first, then Park (Done lives in the ⋯ menu)
        model.moveButtonHighlight(by: 1)
        #expect(model.highlightedButton == .park)
        model.activateSelected()
        #expect(activated.isEmpty)
        #expect(model.presentation.agents.map(\.section) == [.needsYou, .parked])
        #expect(model.highlightedButton == nil)
    }

    @Test func arrowsBelongToTheTextFieldWhileTheSearchHasText() {
        let (model, _, _) = makeModel()
        model.receive(F.snapshot(agents(["a"])))
        model.query = "al"
        #expect(model.moveButtonHighlight(by: 1) == false)
        #expect(model.highlightedButton == nil)
    }

    @Test func escBacksOutOfTheButtonsBeforeItClosesAnything() {
        let (model, _, _) = makeModel()
        model.receive(F.snapshot(agents(["a"])))
        #expect(model.backOutOfButtons() == false)   // nothing to back out of: Esc closes the panel
        model.moveButtonHighlight(by: 1)
        #expect(model.backOutOfButtons())
        #expect(model.highlightedButton == nil)
    }

    /// Done is no longer on the keyboard's list (it lives in the ⋯ menu — press it the way a menu
    /// selection would, `model.press(.done, on:)`), so highlighting a capsule that IS on the list
    /// (Park here) must not itself disturb a confirmation a menu selection started elsewhere on the
    /// row. `cancelConfirmation` is row-scoped rather than button-scoped, though (unchanged by this
    /// task): un-highlighting back to nothing — the same gesture that used to back off the
    /// confirming Done capsule directly — still cancels whatever confirmation the row has pending,
    /// same as Esc (`escCancelsAConfirmPromptStartedWithTheMouse` below covers Esc itself).
    @Test func onlyUnHighlightingAllTheWayOutCancelsAMouseInitiatedConfirmation() async {
        let (model, _, _) = makeModel(script: [.needsConfirmation(reason: "x")])
        model.receive(F.snapshot(agents(["a"])))
        await model.press(.done, on: "a")?.value   // as if chosen from the row's ⋯ menu
        #expect(model.rowActionStates["a"] == .confirming(.done, reason: "x"))
        model.moveButtonHighlight(by: 1)   // highlights Park; merely landing on another button is fine
        #expect(model.rowActionStates["a"] == .confirming(.done, reason: "x"))
        model.moveButtonHighlight(by: -1)   // un-highlights back to nothing
        #expect(model.rowActionStates["a"] == nil)
    }

    @Test func escCancelsAConfirmPromptStartedWithTheMouse() async {
        let (model, _, _) = makeModel(script: [.needsConfirmation(reason: "x")])
        model.receive(F.snapshot(agents(["a"])))
        await model.press(.done, on: "a")?.value
        #expect(model.backOutOfButtons())
        #expect(model.rowActionStates["a"] == nil)
    }

    @Test func movingTheSelectionDropsTheHighlight() {
        let (model, _, _) = makeModel()
        model.receive(F.snapshot(agents(["a", "b"])))
        model.moveButtonHighlight(by: 1)
        model.moveSelection(by: 1)
        #expect(model.highlightedButton == nil)
    }

    @Test func aWorkingClaudeRowHighlightsMessageThenTheMoreActionsMenuOfCompactAndClear() {
        let (model, _, _) = makeModel()
        model.receive(F.snapshot(agents(["w"], section: .working)))
        model.moveButtonHighlight(by: 1)
        #expect(model.highlightedButton == .message)
        model.moveButtonHighlight(by: 1)
        #expect(model.highlightedButton == .moreActions)   // Compact/Clear — no Done/Close pane while working
        model.moveButtonHighlight(by: 1)
        #expect(model.highlightedButton == .moreActions)
    }

    @Test func workingRowsOfOtherCLIsHaveNoButtonsToHighlight() {
        let (model, _, _) = makeModel()
        model.receive(F.snapshot([F.agent("w", section: .working, hasHookData: false)]))
        model.moveButtonHighlight(by: 1)
        #expect(model.highlightedButton == nil)
    }

    @Test func showingThePanelAgainCancelsPendingConfirmations() async {
        let (model, _, _) = makeModel(script: [.needsConfirmation(reason: "x")])
        model.receive(F.snapshot(agents(["a"])))
        await model.press(.done, on: "a")?.value
        model.resetForShow()
        #expect(model.rowActionStates["a"] == nil)
    }

    // MARK: - Compact / Clear (⋯ menu quick commands — straight to `sendDirect`, no validator, no confirm)

    @Test func pressingCompactSendsSlashCompactStraightThroughSendDirect() async {
        let (model, source, _) = makeModel()
        model.receive(F.snapshot(agents(["a"])))
        #expect(model.press(.compact, on: "a") == nil)   // fire-and-forget, like every other direct send
        for _ in 0..<200 where source.messagesSent.isEmpty { await Task.yield() }
        #expect(source.messagesSent == [.init(rowId: "a", text: "/compact", confirmed: true)])
    }

    @Test func pressingClearSendsSlashClearStraightThroughSendDirect() async {
        let (model, source, _) = makeModel()
        model.receive(F.snapshot(agents(["a"])))
        #expect(model.press(.clear, on: "a") == nil)
        for _ in 0..<200 where source.messagesSent.isEmpty { await Task.yield() }
        #expect(source.messagesSent == [.init(rowId: "a", text: "/clear", confirmed: true)])
    }

    @Test func compactAndClearAreNotOfferedOnABlockedRow() {
        let (model, source, _) = makeModel()
        var blocked = F.agent("a", section: .needsYou)
        blocked.blocker = .permission
        model.receive(F.snapshot([blocked]))
        #expect(model.press(.compact, on: "a") == nil)
        #expect(model.press(.clear, on: "a") == nil)
        #expect(source.messagesSent.isEmpty)
    }

    /// Done and Close pane are menu selections too, but they still go through `RowActionMachine` —
    /// the dashboard `perform` call, its busy/confirm/completed bookkeeping, all unchanged by the
    /// menu existing (`doneOnAnIdleAgentStopsItInOnePress` and this file's other Done/Close-pane
    /// tests already prove that end to end; this just pins that they are reachable the way a menu
    /// selection reaches them — `model.press(button, on:)` directly, nothing new).
    @Test func doneAndClosePaneSelectedFromTheMenuStillRouteThroughTheActionMachineNotSendDirect() async {
        let (model, source, _) = makeModel(script: [.succeeded])
        model.receive(F.snapshot(agents(["a"])))
        await model.press(.done, on: "a")?.value
        #expect(source.calls == [.init(kind: .stop, rowId: "a", confirmed: false)])
        #expect(source.messagesSent.isEmpty)
    }
}
