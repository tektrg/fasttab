import Foundation
import Testing
@testable import AgentBar

struct RowButtonsTests {
    typealias F = AgentListFixtures

    private func buttons(_ agent: AgentSnapshot) -> [RowButton] {
        RowButtons.available(for: agent).map(\.button)
    }

    @Test func needsYouRowsOfferDoneThenParkThenMessage() {
        #expect(buttons(F.agent("a", section: .needsYou)) == [.done, .park, .message])
    }

    @Test func parkedRowsOfferUnparkThenDoneThenMessage() {
        #expect(buttons(F.agent("a", section: .parked)) == [.unpark, .done, .message])
    }

    @Test func workingRowsOfferMessageOnly() {
        #expect(buttons(F.agent("a", section: .working)) == [.message])
    }

    // MARK: - Message availability

    @Test func blockedRowsNeverOfferMessage() {
        let blockers: [AgentBlocker] = [
            .question(AnswerFixtures.question()), .questionLoading(nil), .questionNotAnswerable, .permission,
            .permissionReview(PermissionFixtures.bash),
        ]
        for blocker in blockers {
            var agent = F.agent("a", section: .needsYou)
            agent.blocker = blocker
            #expect(!buttons(agent).contains(.message), "\(blocker)")
        }
    }

    @Test func aParkedRowThatIsStillBlockedDoesNotOfferMessage() {
        var agent = F.agent("a", section: .needsYou)
        agent.blocker = .permission
        #expect(buttons(agent.placed(in: .parked)) == [.unpark, .done])
    }

    @Test func endedRowsNeverOfferMessage() {
        #expect(!buttons(F.agent("a", section: .ended)).contains(.message))
        let stopped = F.agent("s", section: .ended, actions: AgentActions(stop: .unavailable, close: .unknown))
        #expect(buttons(stopped) == [.closePane])
    }

    @Test func messageNeedsARowIdALivePaneAndAClaudeAgent() {
        var noRow = F.agent("a", section: .working)
        noRow.rowId = nil
        #expect(buttons(noRow).isEmpty)
        #expect(buttons(F.agent("a", section: .working, canFocus: false)).isEmpty)
        // Not Claude (no hook data): the dashboard's question/permission guard cannot see their boxes.
        #expect(buttons(F.agent("a", section: .working, hasHookData: false)).isEmpty)
        #expect(buttons(F.agent("a", section: .needsYou, hasHookData: false)) == [.done, .park])
    }

    @Test func messageIsAKeyboardStopAfterTheExistingButtons() {
        let agent = F.agent("a", section: .needsYou)
        #expect(RowButtons.usableButtons(for: agent) == [.done, .park, .message])
        #expect(RowActionMachine.plan(pressing: .message, current: nil) == .openMessage)
        #expect(RowButton.message.sessionAction == nil)
        #expect(!RowButton.message.isBlockedAction)   // a neutral grey capsule
    }

    @Test func endedRowsOfferClosePaneOnlyWhileTheDashboardAllowsIt() {
        let stopped = F.agent("s", section: .ended, actions: AgentActions(stop: .unavailable, close: .unknown))
        #expect(buttons(stopped) == [.closePane])
        let gone = F.agent("g", section: .ended, actions: .none)
        #expect(buttons(gone).isEmpty)
    }

    @Test func doneIsDisabledWithTheDashboardsReasonWhenStopIsRefused() throws {
        let refusal = ActionAvailability(isEnabled: false, needsConfirm: false, reason: "refused: the chief's pane can never be stopped from the board")
        let agent = F.agent("a", section: .needsYou, actions: AgentActions(stop: refusal, close: refusal))
        let done = try #require(RowButtons.available(for: agent).first { $0.button == .done })
        #expect(!done.isEnabled)
        #expect(done.disabledReason == "The chief's pane can never be stopped from the board")
        #expect(RowButtons.usableButtons(for: agent) == [.park, .message])   // the keyboard skips it
    }

    @Test func doneNeedsTheDashboardsRowId() throws {
        var agent = F.agent("a", section: .needsYou)
        agent.rowId = nil
        let done = try #require(RowButtons.available(for: agent).first { $0.button == .done })
        #expect(done.disabledReason == RowButtons.missingRowIdReason)
    }

    @Test func parkNeverNeedsTheDashboard() {
        var agent = F.agent("a", section: .needsYou, actions: .none)
        agent.rowId = nil
        #expect(RowButtons.usableButtons(for: agent) == [.park])
    }

    // MARK: - Highlight (←/→)

    private let both: [RowButton] = [.done, .park]

    @Test func rightFromNothingLandsOnTheFirstButton() {
        #expect(RowButtonHighlight.moved(from: nil, by: 1, in: both) == .done)
    }

    @Test func leftFromNothingStaysPut() {
        #expect(RowButtonHighlight.moved(from: nil, by: -1, in: both) == nil)
    }

    @Test func rightWalksToTheLastButtonAndStopsThere() {
        #expect(RowButtonHighlight.moved(from: .done, by: 1, in: both) == .park)
        #expect(RowButtonHighlight.moved(from: .park, by: 1, in: both) == .park)
    }

    @Test func leftPastTheFirstButtonUnHighlights() {
        #expect(RowButtonHighlight.moved(from: .park, by: -1, in: both) == .done)
        #expect(RowButtonHighlight.moved(from: .done, by: -1, in: both) == nil)
    }

    @Test func aRowWithNoButtonsNeverHighlights() {
        #expect(RowButtonHighlight.moved(from: nil, by: 1, in: []) == nil)
    }

    @Test func aHighlightSurvivesOnlyWhileItsButtonExists() {
        #expect(RowButtonHighlight.reconciled(.park, in: both) == .park)
        #expect(RowButtonHighlight.reconciled(.park, in: [.unpark, .done]) == nil)
        #expect(RowButtonHighlight.reconciled(nil, in: both) == nil)
    }
}
