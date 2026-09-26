import Foundation
import Testing
@testable import AgentBar

@MainActor
struct PermissionCardModelTests {
    typealias P = PermissionFixtures

    private final class Recorder {
        var notices: [String] = []
        var decidedAgents: [String] = []
        var endpointMissingReports = 0
        var openedTerminals: [String] = []
    }

    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_000)
    }

    private struct Rig {
        let clock: Clock
        let model: PermissionCardModel
        let source: PermissionFakeSource
        let recorder: Recorder
    }

    private func makeRig(expiry: TimeInterval = PermissionSendTracker.expirySeconds, showing prompt: PermissionPrompt? = P.bash) -> Rig {
        let recorder = Recorder()
        let clock = Clock()
        let model = PermissionCardModel(
            now: { clock.now },
            sendExpirySeconds: expiry,
            loadSessionContext: { _ in SessionContext(latestMessage: "I will remove the lock file.", planFile: nil) }
        )
        let source = PermissionFakeSource()
        if let prompt { source.screen = .screen(lines: P.screen(for: prompt), readAt: clock.now) }
        model.statusSource = source
        model.onNotice = { recorder.notices.append($0) }
        model.onDecided = { recorder.decidedAgents.append($0) }
        model.onEndpointMissing = { recorder.endpointMissingReports += 1 }
        model.onOpenTerminal = { recorder.openedTerminals.append($0) }
        return Rig(clock: clock, model: model, source: source, recorder: recorder)
    }

    private func agent(_ prompt: PermissionPrompt? = P.bash) -> AgentSnapshot { P.agent("a", prompt) }

    private func openReady(_ rig: Rig, _ prompt: PermissionPrompt = P.bash) async {
        rig.model.open(agent(prompt))
        await waitUntil { rig.model.card?.state.phase == .ready }
    }

    // MARK: - Opening

    @Test func opensOnAReviewableBoxShowsTheAgentAndReadsThePaneAndTheTranscript() async {
        let rig = makeRig()
        #expect(rig.model.open(agent()))
        #expect(rig.model.card?.label == "agent a")
        #expect(rig.model.card?.state.phase == .checking)
        await waitUntil { rig.model.card?.state.phase == .ready && rig.model.card?.message != .loading }
        #expect(rig.model.card?.state.prompt == P.bash)
        #expect(rig.model.card?.message == .text("I will remove the lock file."))
        #expect(rig.source.screenReads == 1)
        #expect(rig.source.sent.isEmpty)
    }

    @Test func doesNotOpenOnAnythingButAReviewableBox() {
        let rig = makeRig()
        #expect(!rig.model.open(P.agent("a", nil)))
        #expect(!rig.model.open(AnswerFixtures.blockedAgent("q", blocker: .question(AnswerFixtures.question()))))
        #expect(!rig.model.open(AnswerFixtures.blockedAgent("p", blocker: nil)))
        #expect(!rig.model.open(P.agent("a", P.bash).placed(in: .parked)))
        #expect(!rig.model.isOpen)
    }

    @Test func withoutADashboardItSaysSoAndStaysClosed() {
        let rig = makeRig()
        rig.model.statusSource = nil
        #expect(!rig.model.open(agent()))
        #expect(rig.recorder.notices == [PermissionCardModel.noSourceMessage])
    }

    // MARK: - What is decided is what the pane shows

    @Test func theCardDecidesTheBoxThePaneShowsNotTheFeedsCopy() async {
        let rig = makeRig(showing: P.oneOff)
        await openReady(rig, P.bash)
        #expect(rig.model.card?.state.prompt == P.oneOff)
        #expect(rig.model.card?.state.changedNote == PermissionCardState.changedNoteText)
    }

    @Test func aBoxThePaneNoLongerShowsCannotBeDecided() async {
        let rig = makeRig(showing: nil)
        rig.source.screen = .screen(lines: ["just a shell prompt"], readAt: rig.clock.now)
        rig.model.open(agent())
        await waitUntil { rig.model.card?.state.phase != .checking }
        #expect(rig.model.card?.state.phase == .unavailable(PermissionCardModel.notReadableMessage))
        rig.model.handle(.digit(1))
        rig.model.handle(.enter)
        await settleTasks()
        #expect(rig.source.sent.isEmpty)
    }

    @Test func aFailedPaneReadShowsTheReasonAndOffersTheTerminal() async {
        let rig = makeRig(showing: nil)
        rig.source.screen = .failure("pane w1:p1 not found — likely closed")
        rig.model.open(agent())
        await waitUntil { rig.model.card?.state.phase != .checking }
        #expect(rig.model.card?.state.phase == .unavailable("pane w1:p1 not found — likely closed"))
        rig.model.openTerminal()
        #expect(rig.recorder.openedTerminals == ["a"])
    }

    @Test func nothingIsSentBeforeThePaneHasBeenRead() async {
        let rig = makeRig()
        rig.model.open(agent())
        rig.model.handle(.digit(1))
        rig.model.handle(.enter)
        rig.model.pressSend()
        #expect(rig.source.sent.isEmpty)
        #expect(rig.model.isOpen)
    }

    // MARK: - Sending

    @Test func allowIsOneRequestForTheBoxAsReadAndClosesTheCardAtOnce() async {
        let rig = makeRig()
        await openReady(rig)
        rig.model.handle(.digit(1))
        rig.model.handle(.enter)
        #expect(!rig.model.isOpen)
        await rig.source.waitForRequests(1)
        #expect(rig.source.sent == [.init(paneId: "w1:a", choice: .allow, permission: P.bash)])
        #expect(rig.model.sendingLabel(for: agent()) == "Sending approval…")
        rig.model.handle(.enter)
        rig.model.pressSend()
        await settleTasks()
        #expect(rig.source.sent.count == 1)   // a closed card has no keys
    }

    @Test func denyIsOnePressAndTheRowSaysDenial() async {
        let rig = makeRig()
        await openReady(rig)
        rig.model.handle(.digit(3))
        rig.model.handle(.enter)
        await rig.source.waitForRequests(1)
        #expect(rig.source.sent.first?.choice == .deny)
        #expect(rig.model.sendingLabel(for: agent()) == "Sending denial…")
    }

    @Test func allowAlwaysIsSentOnlyOnTheSecondPress() async {
        let rig = makeRig()
        await openReady(rig)
        rig.model.handle(.digit(2))
        rig.model.handle(.enter)
        await settleTasks()
        #expect(rig.model.isOpen)
        #expect(rig.source.sent.isEmpty)
        rig.model.handle(.enter)
        await rig.source.waitForRequests(1)
        #expect(rig.source.sent.first?.choice == .allowAlways)
    }

    @Test func anyOtherKeyBetweenTheTwoAllowAlwaysPressesStopsIt() async {
        let rig = makeRig()
        await openReady(rig)
        rig.model.handle(.digit(2))
        rig.model.handle(.enter)
        rig.model.handle(.other)
        rig.model.handle(.enter)
        await settleTasks()
        #expect(rig.source.sent.isEmpty)
        #expect(rig.model.isOpen)
    }

    @Test func aSuccessClearsTheRowAndMovesOn() async {
        let rig = makeRig()
        await openReady(rig)
        rig.model.handle(.digit(1))
        rig.model.handle(.enter)
        await rig.source.waitForRequests(1)
        rig.source.reply(.sent(next: nil))
        await waitUntil { !rig.recorder.decidedAgents.isEmpty }
        #expect(rig.recorder.decidedAgents == ["a"])
        // The dashboard's copy lags up to ~15s: the decided box is still "being sent", and cannot be reopened.
        #expect(rig.model.sendingLabel(for: agent()) == "Sending approval…")
        #expect(!rig.model.open(agent()))
        // Once the dashboard shows something else the row is free again.
        rig.model.reconcile(with: [AnswerFixtures.blockedAgent("a", blocker: nil)])
        #expect(rig.model.sendingLabel(for: agent()) == nil)
    }

    @Test func aDecidedBoxIsForgottenAfterTheSafetyWindowEvenIfTheDashboardNeverMoves() async {
        let rig = makeRig()
        await openReady(rig)
        rig.model.handle(.digit(1))
        rig.model.handle(.enter)
        await rig.source.waitForRequests(1)
        rig.source.reply(.sent(next: nil))
        await waitUntil { !rig.recorder.decidedAgents.isEmpty }
        rig.clock.now += PermissionSendTracker.expirySeconds + 1
        #expect(rig.model.sendingLabel(for: agent()) == nil)
    }

    @Test func aReplyNamingAnotherBoxPutsTheRowBackToReviewOnThatBox() async {
        let rig = makeRig()
        await openReady(rig)
        rig.model.handle(.digit(1))
        rig.model.handle(.enter)
        await rig.source.waitForRequests(1)
        rig.source.reply(.sent(next: P.oneOff))
        await waitUntil { rig.model.sendingLabel(for: self.agent()) == nil }
        #expect(rig.recorder.decidedAgents.isEmpty)        // not finished: another box follows
        rig.source.screen = .screen(lines: P.screen(for: P.oneOff), readAt: rig.clock.now)
        // The feed still shows the old box; Review opens on the next one.
        #expect(rig.model.open(agent(P.bash)))
        #expect(rig.model.card?.state.prompt == P.oneOff)
        await waitUntil { rig.model.card?.state.phase == .ready }
        #expect(rig.model.card?.state.prompt == P.oneOff)
    }

    @Test func aRefusalFreesTheRowShowsTheDashboardsWordsAndKeepsNoDraft() async {
        let rig = makeRig()
        await openReady(rig)
        rig.model.handle(.digit(1))
        rig.model.handle(.enter)
        await rig.source.waitForRequests(1)
        rig.source.reply(.failed("permission prompt changed or gone — re-check the pane"))
        await waitUntil { !rig.recorder.notices.isEmpty }
        #expect(rig.recorder.notices == ["Approval not sent: permission prompt changed or gone — re-check the pane"])
        #expect(rig.model.sendingLabel(for: agent()) == nil)
        #expect(rig.recorder.decidedAgents.isEmpty)
        // Reopening starts fresh: nothing highlighted, nothing carried over.
        await openReady(rig)
        #expect(rig.model.card?.state.highlighted == nil)
        #expect(rig.source.sent.count == 1)   // and nothing was retried
    }

    @Test func aDeniedRefusalSaysDenial() async {
        let rig = makeRig()
        await openReady(rig)
        rig.model.handle(.digit(3))
        rig.model.handle(.enter)
        await rig.source.waitForRequests(1)
        rig.source.reply(.failed("Can't reach the status dashboard."))
        await waitUntil { !rig.recorder.notices.isEmpty }
        #expect(rig.recorder.notices == ["Denial not sent: Can't reach the status dashboard."])
    }

    @Test func aSendWithNoReplyFreesTheRowAndSaysTheDecisionMayHaveGoneThrough() async {
        let rig = makeRig(expiry: 0.4)
        await openReady(rig)
        rig.model.handle(.digit(1))
        rig.model.handle(.enter)
        await rig.source.waitForRequests(1)
        #expect(rig.model.sendingLabel(for: agent()) != nil)
        await waitUntil { !rig.recorder.notices.isEmpty }
        #expect(rig.recorder.notices == [PermissionCardModel.noReplyMessage])
        #expect(rig.model.sendingLabel(for: agent()) == nil)
        rig.source.reply(.sent(next: nil))   // a reply that arrives after the expiry is ignored
        await settleTasks()
        #expect(rig.recorder.decidedAgents.isEmpty)
    }

    @Test func aSecondDecisionForTheSameAgentWhileOneIsOnItsWayIsNotSent() async {
        let rig = makeRig()
        await openReady(rig)
        rig.model.handle(.digit(1))
        rig.model.handle(.enter)
        await rig.source.waitForRequests(1)
        #expect(!rig.model.open(agent()))
        #expect(rig.source.sent.count == 1)
    }

    @Test func aDecisionNeverAnswersAQuestion() async {
        let rig = makeRig()
        await openReady(rig)
        rig.model.handle(.digit(1))
        rig.model.handle(.enter)
        await rig.source.waitForRequests(1)
        #expect(rig.source.answersAttempted == 0)
    }

    // MARK: - A dashboard without the endpoint

    @Test func aDashboardWithoutTheEndpointShowsItsReplyAndFallsBackToOpenTerminal() async {
        let rig = makeRig()
        await openReady(rig)
        rig.model.handle(.digit(1))
        rig.model.handle(.enter)
        await rig.source.waitForRequests(1)
        rig.source.reply(.unsupported("not found"))
        await waitUntil { rig.recorder.endpointMissingReports == 1 }
        #expect(rig.recorder.notices.count == 1)
        #expect(rig.recorder.notices[0].hasPrefix("Approval not sent: the dashboard replied \"not found\""))
        #expect(rig.recorder.notices[0].contains("Open terminal"))
        #expect(rig.model.sendingLabel(for: agent()) == nil)
        // Review turns back into Open terminal for a while, then returns.
        let review = agent()
        #expect(rig.model.withoutReviewIfEndpointMissing([review]).first?.blocker == .permission)
        rig.clock.now += PermissionCardModel.endpointMissingSeconds + 1
        #expect(rig.model.withoutReviewIfEndpointMissing([review]).first?.blocker == .permissionReview(P.bash))
    }

    @Test func resettingForAnotherDashboardForgetsThatItLackedTheEndpoint() async {
        let rig = makeRig()
        await openReady(rig)
        rig.model.handle(.digit(1))
        rig.model.handle(.enter)
        await rig.source.waitForRequests(1)
        rig.source.reply(.unsupported("not found"))
        await waitUntil { rig.recorder.endpointMissingReports == 1 }
        rig.model.reset()
        #expect(rig.model.withoutReviewIfEndpointMissing([agent()]).first?.blocker == .permissionReview(P.bash))
    }

    // MARK: - Following the dashboard

    @Test func theCardClosesWhenTheAgentIsNoLongerBlockedOnABox() async {
        let rig = makeRig()
        await openReady(rig)
        rig.model.reconcile(with: [AnswerFixtures.blockedAgent("a", blocker: nil)])
        #expect(!rig.model.isOpen)
    }

    @Test func theCardClosesWhenTheRowIsGone() async {
        let rig = makeRig()
        await openReady(rig)
        rig.model.reconcile(with: [])
        #expect(!rig.model.isOpen)
    }

    @Test func theCardStaysWhileTheFeedFlapsBetweenParsedAndPlain() async {
        let rig = makeRig()
        await openReady(rig)
        rig.model.handle(.digit(3))
        rig.model.reconcile(with: [P.agent("a", nil)])
        #expect(rig.model.card?.state.highlighted == .deny)
        rig.model.reconcile(with: [P.agent("a", P.bash)])
        #expect(rig.model.card?.state.highlighted == .deny)
    }

    @Test func aFeedShowingADifferentBoxNeverSwapsTheBoxUnderTheUsersFinger() async {
        let rig = makeRig()
        await openReady(rig)
        rig.model.handle(.digit(3))
        rig.model.reconcile(with: [P.agent("a", P.oneOff)])
        #expect(rig.model.card?.state.prompt == P.bash)
        #expect(rig.model.card?.state.highlighted == .deny)
    }

    @Test func aReassignedPaneIdIsPickedUpWhileTheCardStaysOpenSoASendDoesNotHitAStalePane() async {
        let rig = makeRig()
        await openReady(rig)
        // herdr moved this still-live session to a new pane while the card sat open; the dashboard's
        // next poll reflects it, same box, same agent.
        rig.model.reconcile(with: [P.agent("a", P.bash, paneId: "w1:a-new")])
        rig.model.handle(.digit(1))
        rig.model.handle(.enter)
        await rig.source.waitForRequests(1)
        #expect(rig.source.sent == [.init(paneId: "w1:a-new", choice: .allow, permission: P.bash)])
    }

    @Test func theCardClosesWhenTheAgentTurnsIntoAQuestion() async {
        let rig = makeRig()
        await openReady(rig)
        rig.model.reconcile(with: [AnswerFixtures.blockedAgent("a", blocker: .question(AnswerFixtures.question()))])
        #expect(!rig.model.isOpen)
    }

    @Test func aBoxJustDecidedThatIsStillOnScreenIsNotOfferedAgain() async {
        let rig = makeRig()
        await openReady(rig)
        rig.model.handle(.digit(1))
        rig.model.handle(.enter)
        await rig.source.waitForRequests(1)
        rig.source.reply(.sent(next: nil))
        await waitUntil { !rig.recorder.decidedAgents.isEmpty }
        rig.clock.now += PermissionSendTracker.expirySeconds + 1
        // The window passed, the feed still shows the box, and so does the pane: the card must still not allow it twice.
        let opened = rig.model.open(agent())
        #expect(!opened)
        #expect(rig.recorder.notices.last == PermissionCardModel.alreadyDecidedMessage)
    }

    @Test func aCardForAnotherAgentIsNotTouchedByALateReadOfAnEarlierOne() async {
        let rig = makeRig()
        rig.model.open(agent())
        rig.model.close()
        rig.model.open(P.agent("b", P.oneOff))
        rig.source.screen = .screen(lines: P.screen(for: P.oneOff), readAt: rig.clock.now)
        await waitUntil { rig.model.card?.state.phase == .ready }
        #expect(rig.model.card?.agentID == "b")
    }
}
