import Foundation
import Testing
@testable import AgentBar

struct RowButtonsTests {
    typealias F = AgentListFixtures

    private func buttons(_ agent: AgentSnapshot) -> [RowButton] {
        RowButtons.available(for: agent).map(\.button)
    }

    private func menuItems(_ agent: AgentSnapshot) -> [RowButton] {
        RowButtons.menuItems(for: agent).map(\.button)
    }

    @Test func needsYouRowsOfferParkThenMessageThenTheMoreActionsMenu() {
        #expect(buttons(F.agent("a", section: .needsYou)) == [.park, .message, .moreActions])
        #expect(menuItems(F.agent("a", section: .needsYou)) == [.done, .compact, .clear])
    }

    @Test func parkedRowsOfferUnparkThenMessageThenTheMoreActionsMenu() {
        #expect(buttons(F.agent("a", section: .parked)) == [.unpark, .message, .moreActions])
        #expect(menuItems(F.agent("a", section: .parked)) == [.done, .compact, .clear])
    }

    @Test func workingRowsOfferMessageThenTheMoreActionsMenuOfCompactAndClearOnly() {
        #expect(buttons(F.agent("a", section: .working)) == [.message, .moreActions])
        #expect(menuItems(F.agent("a", section: .working)) == [.compact, .clear])   // no Done/Close pane while working
    }

    // MARK: - Message / Compact / Clear share one eligibility gate

    @Test func blockedRowsNeverOfferMessageOrCompactOrClear() {
        let blockers: [AgentBlocker] = [
            .question(AnswerFixtures.question()), .questionLoading(nil), .questionNotAnswerable, .permission,
            .permissionReview(PermissionFixtures.bash),
        ]
        for blocker in blockers {
            var agent = F.agent("a", section: .needsYou)
            agent.blocker = blocker
            #expect(!buttons(agent).contains(.message), "\(blocker)")
            // A blocked needsYou row's strip is Answer/Review/Open terminal + Park (unchanged by
            // this task) and its ⋯ menu is empty entirely — Done/Compact/Clear only apply once the
            // row is cleared of its blocker.
            #expect(menuItems(agent).isEmpty, "\(blocker)")
        }
    }

    @Test func aParkedRowThatIsStillBlockedDoesNotOfferMessageButStillOffersDoneInTheMenu() {
        var agent = F.agent("a", section: .needsYou)
        agent.blocker = .permission
        let parked = agent.placed(in: .parked)
        #expect(buttons(parked) == [.unpark, .moreActions])
        #expect(menuItems(parked) == [.done])   // still parkable/stoppable; just not messageable
    }

    @Test func endedRowsNeverOfferMessage() {
        #expect(!buttons(F.agent("a", section: .ended)).contains(.message))
        let stopped = F.agent("s", section: .ended, actions: AgentActions(stop: .unavailable, close: .unknown))
        #expect(buttons(stopped) == [.moreActions])
        #expect(menuItems(stopped) == [.closePane])
    }

    @Test func messageNeedsARowIdALivePaneAndAClaudeAgent() {
        var noRow = F.agent("a", section: .working)
        noRow.rowId = nil
        #expect(buttons(noRow).isEmpty)
        #expect(buttons(F.agent("a", section: .working, canFocus: false)).isEmpty)
        // Not Claude (no hook data): the dashboard's question/permission guard cannot see their boxes.
        #expect(buttons(F.agent("a", section: .working, hasHookData: false)).isEmpty)
        let noHookData = F.agent("a", section: .needsYou, hasHookData: false)
        #expect(buttons(noHookData) == [.park, .moreActions])
        #expect(menuItems(noHookData) == [.done])   // Done doesn't need hook data; Compact/Clear do
    }

    @Test func moreActionsIsAKeyboardStopAfterTheExistingButtons() {
        let agent = F.agent("a", section: .needsYou)
        #expect(RowButtons.usableButtons(for: agent) == [.park, .message, .moreActions])
        #expect(RowActionMachine.plan(pressing: .message, current: nil) == .openMessage)
        #expect(RowButton.message.sessionAction == nil)
        #expect(!RowButton.message.isBlockedAction)   // a neutral grey capsule
        #expect(RowActionMachine.plan(pressing: .moreActions, current: nil) == .ignore)   // opened by a click, not Enter
    }

    @Test func endedRowsOfferTheMoreActionsMenuOnlyWhileTheDashboardAllowsClose() {
        let stopped = F.agent("s", section: .ended, actions: AgentActions(stop: .unavailable, close: .unknown))
        #expect(buttons(stopped) == [.moreActions])
        let gone = F.agent("g", section: .ended, actions: .none)
        #expect(buttons(gone).isEmpty)
    }

    @Test func doneIsDisabledWithTheDashboardsReasonWhenStopIsRefused() throws {
        let refusal = ActionAvailability(isEnabled: false, needsConfirm: false, reason: "refused: the chief's pane can never be stopped from the board")
        let agent = F.agent("a", section: .needsYou, actions: AgentActions(stop: refusal, close: refusal))
        let done = try #require(RowButtons.menuItems(for: agent).first { $0.button == .done })
        #expect(!done.isEnabled)
        #expect(done.disabledReason == "The chief's pane can never be stopped from the board")
        // The ⋯ trigger still shows: Compact/Clear inside it are still usable even though Done isn't.
        #expect(RowButtons.usableButtons(for: agent) == [.park, .message, .moreActions])
        #expect(!RowButtons.isPressable(.done, on: agent))
    }

    @Test func doneNeedsTheDashboardsRowId() throws {
        var agent = F.agent("a", section: .needsYou)
        agent.rowId = nil
        let done = try #require(RowButtons.menuItems(for: agent).first { $0.button == .done })
        #expect(done.disabledReason == RowButtons.missingRowIdReason)
    }

    @Test func parkNeverNeedsTheDashboard() {
        var agent = F.agent("a", section: .needsYou, actions: .none)
        agent.rowId = nil
        // No row id: Done (needs it) and Compact/Clear (need Message eligibility, which needs it
        // too) are all unusable, so the ⋯ trigger itself does not show — never a menu that opens
        // onto nothing.
        #expect(RowButtons.usableButtons(for: agent) == [.park])
    }

    // MARK: - The ⋯ menu itself (Done / Close pane / Compact / Clear)

    @Test func isPressableAuthorizesMenuItemsEvenThoughTheyAreNeverInTheCapsuleStrip() {
        let agent = F.agent("a", section: .needsYou)
        #expect(!RowButtons.available(for: agent).map(\.button).contains(.done))
        #expect(RowButtons.isPressable(.done, on: agent))
        #expect(RowButtons.isPressable(.compact, on: agent))
        #expect(RowButtons.isPressable(.clear, on: agent))
        #expect(!RowButtons.isPressable(.closePane, on: agent))   // not this row's section
    }

    @Test func aRowWithNoMessageEligibilityStillOffersDoneAloneInTheMenu() {
        let notClaude = F.agent("a", section: .needsYou, hasHookData: false)
        #expect(RowButtons.menuItems(for: notClaude).map(\.button) == [.done])
        #expect(RowButtons.isPressable(.done, on: notClaude))
        #expect(!RowButtons.isPressable(.compact, on: notClaude))
    }

    // MARK: - Highlight (←/→)

    private let both: [RowButton] = [.park, .moreActions]

    @Test func rightFromNothingLandsOnTheFirstButton() {
        #expect(RowButtonHighlight.moved(from: nil, by: 1, in: both) == .park)
    }

    @Test func leftFromNothingStaysPut() {
        #expect(RowButtonHighlight.moved(from: nil, by: -1, in: both) == nil)
    }

    @Test func rightWalksToTheLastButtonAndStopsThere() {
        #expect(RowButtonHighlight.moved(from: .park, by: 1, in: both) == .moreActions)
        #expect(RowButtonHighlight.moved(from: .moreActions, by: 1, in: both) == .moreActions)
    }

    @Test func leftPastTheFirstButtonUnHighlights() {
        #expect(RowButtonHighlight.moved(from: .moreActions, by: -1, in: both) == .park)
        #expect(RowButtonHighlight.moved(from: .park, by: -1, in: both) == nil)
    }

    @Test func aRowWithNoButtonsNeverHighlights() {
        #expect(RowButtonHighlight.moved(from: nil, by: 1, in: []) == nil)
    }

    @Test func aHighlightSurvivesOnlyWhileItsButtonExists() {
        #expect(RowButtonHighlight.reconciled(.park, in: both) == .park)
        #expect(RowButtonHighlight.reconciled(.park, in: [.unpark, .moreActions]) == nil)
        #expect(RowButtonHighlight.reconciled(nil, in: both) == nil)
    }
}
