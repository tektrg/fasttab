import Foundation
import Testing
@testable import AgentBar

struct RowActionMachineTests {
    private func plan(_ button: RowButton, _ state: RowActionState?) -> RowActionPlan {
        RowActionMachine.plan(pressing: button, current: state)
    }

    @Test func firstPressOfDoneSendsStopUnconfirmed() {
        #expect(plan(.done, nil) == .send(.stop, confirmed: false))
    }

    @Test func secondPressAfterAConfirmRequestSendsConfirmed() {
        #expect(plan(.done, .confirming(.done, reason: "3 uncommitted files")) == .send(.stop, confirmed: true))
    }

    @Test func closePaneMapsToTheCloseRequest() {
        #expect(plan(.closePane, nil) == .send(.close, confirmed: false))
        #expect(plan(.closePane, .confirming(.closePane, reason: "x")) == .send(.close, confirmed: true))
    }

    @Test func parkAndUnparkAreLocal() {
        #expect(plan(.park, nil) == .park)
        #expect(plan(.unpark, nil) == .unpark)
    }

    @Test func nothingIsSentWhileARequestIsInFlightOrAlreadyDone() {
        #expect(plan(.done, .busy(.done)) == .ignore)
        #expect(plan(.park, .busy(.done)) == .ignore)
        #expect(plan(.done, .completed(.done)) == .ignore)
    }

    @Test func parkingWhileAConfirmationIsPendingIsAllowed() {
        #expect(plan(.park, .confirming(.done, reason: "x")) == .park)
    }

    @Test func pressingADifferentButtonAfterAConfirmStartsOverUnconfirmed() {
        #expect(plan(.closePane, .confirming(.done, reason: "x")) == .send(.close, confirmed: false))
    }

    @Test func outcomesMapToRowStates() {
        let done = RowActionMachine.state(after: .succeeded, pressing: .done)
        #expect(done.state == .completed(.done) && done.failure == nil)
        let confirm = RowActionMachine.state(after: .needsConfirmation(reason: "9 uncommitted files"), pressing: .done)
        #expect(confirm.state == .confirming(.done, reason: "9 uncommitted files") && confirm.failure == nil)
        let failed = RowActionMachine.state(after: .failed("pane is gone"), pressing: .closePane)
        #expect(failed.state == nil && failed.failure == "pane is gone")
    }
}

struct RowActionTextTests {
    @Test func reasonsAreTidiedForARow() {
        #expect(RowActionText.plainReason("blocked · 3 uncommitted files · 10.0 MB") == "Blocked, 3 uncommitted files, 10.0 MB")
        #expect(RowActionText.plainReason("refused: pane is already gone") == "Pane is already gone")
        #expect(RowActionText.plainReason("  ") == nil)
        #expect(RowActionText.plainReason(nil) == nil)
    }

    @Test func confirmPromptNamesTheStake() {
        #expect(RowActionText.confirmPrompt(kind: .stop, reason: "9 uncommitted files") == "9 uncommitted files. Confirm?")
        #expect(RowActionText.confirmPrompt(kind: .stop, reason: "") == "Stops the agent. Confirm?")
        #expect(RowActionText.confirmPrompt(kind: .close, reason: "") == "Closes the pane. Confirm?")
    }

    @Test func buttonTitlesFollowTheirOwnState() {
        #expect(RowActionText.title(of: .done, state: nil) == "Done")
        #expect(RowActionText.title(of: .done, state: .busy(.done)) == "Stopping…")
        #expect(RowActionText.title(of: .done, state: .confirming(.done, reason: "x")) == "Confirm")
        #expect(RowActionText.title(of: .done, state: .completed(.done)) == "Stopped")
        #expect(RowActionText.title(of: .closePane, state: .busy(.closePane)) == "Closing…")
        #expect(RowActionText.title(of: .park, state: .busy(.done)) == "Park")   // another button's state
    }

    @Test func failureNoticesAreFullSentences() {
        #expect(RowActionText.failureNotice(kind: .stop, message: "refused: nothing to stop") == "Couldn't finish that agent: Nothing to stop")
        #expect(RowActionText.failureNotice(kind: .close, message: "Can't reach the status dashboard.") == "Couldn't close that pane: Can't reach the status dashboard")
    }

    @Test func footerHintsFollowTheFieldAndTheHighlight() {
        typealias Hints = PanelFooterHints
        #expect(Hints.text(for: .init()).contains("←→ actions"))
        #expect(Hints.text(for: .init()).contains("space peek"))
        #expect(Hints.text(for: .init(hasDismissibleNotice: true)).hasPrefix("esc dismiss notice"))
        #expect(Hints.text(for: .init(answerMode: .singleSelect, hasDismissibleNotice: true)).hasPrefix("esc dismiss notice"))
        #expect(!Hints.text(for: .init(searchIsEmpty: false)).contains("←→"))   // arrows belong to the text field
        #expect(!Hints.text(for: .init(searchIsEmpty: false)).contains("space"))
        #expect(Hints.text(for: .init(hasHighlightedButton: true)) == "←→ button   ↩ press   esc back")
        #expect(Hints.text(for: .init(isPeeking: true)) == "space/esc back   ↩ switch")
    }
}
