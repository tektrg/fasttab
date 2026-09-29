import Foundation
import Testing
@testable import AgentBar

/// The permission card as the panel drives it: rows, keys, selection, footer and flapping, against a fake dashboard.
@MainActor
struct PermissionPanelModelTests {
    typealias P = PermissionFixtures
    typealias F = AgentListFixtures

    private final class Clock { var now = F.now }

    private struct Rig {
        let model: AgentPanelModel
        let source: PermissionFakeSource
        let clock: Clock
    }

    private func makeRig(_ agents: [AgentSnapshot]) -> Rig {
        let defaults = makeScratchDefaults("permission-panel")
        let clock = Clock()
        let permission = PermissionCardModel(now: { clock.now }, loadSessionContext: { _ in .empty })
        let model = AgentPanelModel(
            store: FrecencyStore(defaults: defaults),
            triageStore: TriageStore(defaults: defaults),
            answer: AnswerCardModel(loadSessionContext: { _ in .empty }, openFile: { _ in }),
            permission: permission,
            now: { clock.now }
        )
        let source = PermissionFakeSource()
        source.screen = .screen(lines: P.screen(for: P.bash), readAt: clock.now)
        model.statusSource = source
        model.receive(F.snapshot(agents))
        return Rig(model: model, source: source, clock: clock)
    }

    private func openCard(_ rig: Rig, id: String = "a") async {
        rig.model.press(.review, on: id)
        await waitUntil { rig.model.permission.card?.state.phase == .ready }
    }

    private func decide(_ rig: Rig, digit: Int) async {
        rig.model.permission.handle(.digit(digit))
        rig.model.activateSelected()
        await rig.source.waitForRequests(1)
    }

    // MARK: - Opening from the row

    @Test func aReviewableRowShowsReviewAndParkAndReviewOpensTheCard() {
        let rig = makeRig([F.agent("done"), P.agent("a", P.bash)])
        #expect(rig.model.presentation.agents.map(\.id) == ["a", "done"])
        #expect(RowButtons.usableButtons(for: rig.model.presentation.agents[0]) == [.review, .peek, .park])
        rig.model.press(.review, on: "a")
        #expect(rig.model.permission.card?.agentID == "a")
        #expect(rig.model.isCardOpen)
        #expect(!rig.model.answer.isOpen)
    }

    @Test func aPlainBlockedRowStillOnlyOpensTheTerminal() {
        let rig = makeRig([P.agent("a", nil)])
        rig.model.press(.review, on: "a")   // not offered: nothing happens
        #expect(!rig.model.isCardOpen)
        #expect(RowButtons.usableButtons(for: rig.model.presentation.agents[0]) == [.openTerminal, .peek, .park])
    }

    @Test func enterOnTheHighlightedReviewButtonOpensTheCard() {
        let rig = makeRig([P.agent("a", P.bash)])
        rig.model.moveButtonHighlight(by: 1)
        #expect(rig.model.highlightedButton == .review)
        rig.model.activateSelected()
        #expect(rig.model.permission.isOpen)
    }

    // MARK: - Keys while the card is open

    @Test func arrowsDigitsEnterAndEscapeDriveTheCardNotTheList() async {
        let rig = makeRig([P.agent("a", P.bash), F.agent("done")])
        await openCard(rig)
        rig.model.moveSelectionOrAnswerHighlight(by: 1)
        #expect(rig.model.permission.card?.state.highlighted == .allow)
        rig.model.handleCardDigit(3)
        #expect(rig.model.permission.card?.state.highlighted == .deny)
        #expect(rig.model.selectedAgentID == "a")
        rig.model.activateSelected()
        await rig.source.waitForRequests(1)
        #expect(rig.source.sent.first?.choice == .deny)
        #expect(!rig.model.isCardOpen)
    }

    @Test func enterWithNothingHighlightedSendsNothing() async {
        let rig = makeRig([P.agent("a", P.bash)])
        await openCard(rig)
        rig.model.activateSelected()
        await settleTasks()
        #expect(rig.source.sent.isEmpty)
        #expect(rig.model.permission.isOpen)
    }

    @Test func escapeGoesBackToTheListAndAnAllowAlwaysConfirmationIsCancelledFirst() async {
        let rig = makeRig([P.agent("a", P.bash)])
        await openCard(rig)
        rig.model.handleCardDigit(2)
        rig.model.activateSelected()
        #expect(rig.model.permission.card?.state.isConfirmingAlways == true)
        #expect(rig.model.backOutOfButtons())
        #expect(rig.model.permission.card?.state.isConfirmingAlways == false)
        #expect(rig.model.permission.isOpen)
        #expect(rig.model.backOutOfButtons())
        #expect(!rig.model.permission.isOpen)
    }

    @Test func spaceAndArrowsSidewaysAndStrayCharactersCancelAPendingAllowAlways() async {
        let rig = makeRig([P.agent("a", P.bash)])
        await openCard(rig)
        for cancel in [{ rig.model.togglePeek() }, { rig.model.moveButtonHighlight(by: 1) }, { rig.model.handleCardStrayKey(); return true }] {
            rig.model.handleCardDigit(2)
            rig.model.activateSelected()
            #expect(rig.model.permission.card?.state.isConfirmingAlways == true)
            _ = cancel()
            #expect(rig.model.permission.card?.state.isConfirmingAlways == false)
        }
        await settleTasks()
        #expect(rig.source.sent.isEmpty)
    }

    @Test func spaceDoesNotOpenAPeekBehindTheCard() async {
        let rig = makeRig([P.agent("a", P.bash)])
        await openCard(rig)
        #expect(rig.model.togglePeek())
        #expect(rig.model.peek == nil)
    }

    @Test func showingThePanelAgainClosesTheCard() async {
        let rig = makeRig([P.agent("a", P.bash)])
        await openCard(rig)
        rig.model.resetForShow()
        #expect(!rig.model.isCardOpen)
    }

    @Test func openingOneKindOfCardClosesTheOther() async {
        let question = AnswerFixtures.question()
        let rig = makeRig([P.agent("a", P.bash), AnswerFixtures.blockedAgent("q", blocker: .question(question))])
        await openCard(rig)
        rig.model.press(.answer, on: "q")
        #expect(rig.model.answer.isOpen)
        #expect(!rig.model.permission.isOpen)
        rig.model.press(.review, on: "a")
        #expect(rig.model.permission.isOpen)
        #expect(!rig.model.answer.isOpen)
    }

    // MARK: - After sending

    @Test func theRowShowsASpinnerAndNoButtonsThenAdvancesToTheNextBlockedRow() async {
        let rig = makeRig([P.agent("a", P.bash), P.agent("b", P.oneOff), F.agent("done")])
        await openCard(rig)
        await decide(rig, digit: 1)
        let row = try? #require(rig.model.presentation.agents.first { $0.id == "a" })
        #expect(row.flatMap(rig.model.sendingLabel(for:)) == "Sending approval…")
        #expect(rig.model.press(.review, on: "a") == nil)
        #expect(!rig.model.permission.isOpen)
        rig.source.reply(.sent(next: nil))
        await waitUntil { rig.model.selectedAgentID == "b" }
        #expect(rig.model.selectedAgentID == "b")
    }

    @Test func aDenialSaysDenialOnTheRow() async {
        let rig = makeRig([P.agent("a", P.bash)])
        await openCard(rig)
        await decide(rig, digit: 3)
        #expect(rig.model.sendingLabel(for: rig.model.presentation.agents[0]) == "Sending denial…")
    }

    @Test func aRefusalShowsTheDashboardsWordsInTheFooterAndFreesTheRow() async {
        let rig = makeRig([P.agent("a", P.bash)])
        await openCard(rig)
        await decide(rig, digit: 1)
        rig.source.reply(.failed("permission prompt changed or gone — re-check the pane"))
        await waitUntil { rig.model.footerNotice != nil }
        #expect(rig.model.footerNotice == .actionFailed("Approval not sent: permission prompt changed or gone — re-check the pane"))
        #expect(rig.model.sendingLabel(for: rig.model.presentation.agents[0]) == nil)
        #expect(RowButtons.usableButtons(for: rig.model.presentation.agents[0]) == [.review, .peek, .park])
    }

    @Test func aDecidedBoxCannotBeReopenedWhileTheDashboardCatchesUp() async {
        let rig = makeRig([P.agent("a", P.bash)])
        await openCard(rig)
        await decide(rig, digit: 1)
        rig.source.reply(.sent(next: nil))
        await settleTasks()   // the reply is taken: the send is over, the dashboard's copy has not moved yet
        // A feed update that still shows the same box (up to ~15s behind the pane).
        rig.model.receive(F.snapshot([P.agent("a", P.bash)]))
        #expect(rig.model.sendingLabel(for: rig.model.presentation.agents[0]) == "Sending approval…")
        #expect(RowButtons.usableButtons(for: rig.model.presentation.agents[0]) == [.review, .peek, .park])
        rig.model.press(.review, on: "a")
        #expect(!rig.model.permission.isOpen)
        // The dashboard catches up: the row leaves Needs you.
        rig.model.receive(F.snapshot([F.agent("a", section: .working)]))
        #expect(rig.model.sendingLabel(for: rig.model.presentation.agents[0]) == nil)
    }

    // MARK: - Flapping

    @Test func reviewStaysSteadyWhileTheDashboardFlapsBetweenParsedAndPlain() {
        let rig = makeRig([P.agent("a", P.bash)])
        rig.model.receive(F.snapshot([P.agent("a", nil)]))
        #expect(rig.model.presentation.agents.first?.blockedOnYou == .permissionReview(P.bash))
        #expect(RowButtons.usableButtons(for: rig.model.presentation.agents[0]) == [.review, .peek, .park])
        rig.model.receive(F.snapshot([P.agent("a", P.bash)]))
        #expect(rig.model.presentation.agents.first?.blockedOnYou == .permissionReview(P.bash))
    }

    @Test func aRowThatWasNeverParsedNeverGrowsAReviewButton() {
        let rig = makeRig([P.agent("a", nil)])
        rig.model.receive(F.snapshot([P.agent("a", nil)]))
        #expect(RowButtons.usableButtons(for: rig.model.presentation.agents[0]) == [.openTerminal, .peek, .park])
    }

    @Test func reviewGoesAwayOnceTheAgentIsNoLongerBlocked() {
        let rig = makeRig([P.agent("a", P.bash)])
        rig.model.receive(F.snapshot([F.agent("a", section: .working)]))
        rig.model.receive(F.snapshot([P.agent("a", nil)]))
        #expect(rig.model.presentation.agents.first?.blockedOnYou == .permission)   // no memory left to steady it
    }

    // MARK: - A dashboard without the endpoint

    @Test func aDashboardThatLacksTheEndpointTurnsReviewBackIntoOpenTerminalWithTheReplyInTheFooter() async {
        let rig = makeRig([P.agent("a", P.bash)])
        await openCard(rig)
        await decide(rig, digit: 1)
        rig.source.reply(.unsupported("not found"))
        await waitUntil { rig.model.footerNotice != nil }
        guard case .actionFailed(let sentence)? = rig.model.footerNotice else {
            Issue.record("expected a footer notice")
            return
        }
        #expect(sentence.contains("not found"))
        #expect(sentence.contains("Open terminal"))
        #expect(RowButtons.usableButtons(for: rig.model.presentation.agents[0]) == [.openTerminal, .peek, .park])
        // The feed keeps saying it is parseable: still terminal only, until the memory lapses.
        rig.model.receive(F.snapshot([P.agent("a", P.bash)]))
        #expect(RowButtons.usableButtons(for: rig.model.presentation.agents[0]) == [.openTerminal, .peek, .park])
        rig.clock.now += PermissionCardModel.endpointMissingSeconds + 1
        rig.model.receive(F.snapshot([P.agent("a", P.bash)]))
        #expect(RowButtons.usableButtons(for: rig.model.presentation.agents[0]) == [.review, .peek, .park])
    }

    @Test func aNewDashboardAddressForgetsThatTheOldOneLackedTheEndpoint() async {
        let rig = makeRig([P.agent("a", P.bash)])
        await openCard(rig)
        await decide(rig, digit: 1)
        rig.source.reply(.unsupported("not found"))
        await waitUntil { rig.model.footerNotice != nil }
        rig.model.useDashboard(address: "127.0.0.1:47999")
        rig.model.receive(F.snapshot([P.agent("a", P.bash)]))
        #expect(RowButtons.usableButtons(for: rig.model.presentation.agents[0]) == [.review, .peek, .park])
    }

    // MARK: - Footer hints

    @Test func theFooterHintsFollowThePermissionCard() async {
        let rig = makeRig([P.agent("a", P.bash)])
        await openCard(rig)
        let hint = { PanelFooterHints.text(for: .init(permissionMode: rig.model.permission.card?.state.hintMode)) }
        #expect(hint() == "↑↓ or number to choose   ⌘C copy info   esc back")
        rig.model.handleCardDigit(2)
        #expect(hint() == "↑↓ change   ↩ press   ⌘C copy info   esc back")
        rig.model.activateSelected()
        #expect(hint() == "↩ confirm always allow   any other key cancels")
    }
}
