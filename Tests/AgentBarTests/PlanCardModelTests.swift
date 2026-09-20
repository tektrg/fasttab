import Foundation
import Testing
@testable import AgentBar

/// The plan card as the model drives it: opening, the plan file, choosing, the second press, feedback,
/// the last look at the pane, refusals and timeouts, against a fake dashboard (never a real one).
@MainActor
struct PlanCardModelTests {
    typealias F = PlanFixtures
    typealias P = PermissionFixtures

    private final class Recorder: @unchecked Sendable {
        var notices: [String] = []
        var decidedAgents: [String] = []
        var releasedKeyboard = 0
        private let lock = NSLock()
        private var paths: [String?] = []
        var loadedPaths: [String?] { lock.withLock { paths } }
        func loaded(_ path: String?) { lock.withLock { paths.append(path) } }
    }

    private struct Rig {
        let model: PermissionCardModel
        let source: PermissionFakeSource
        let recorder: Recorder
    }

    private func makeRig(
        expiry: TimeInterval = PermissionSendTracker.expirySeconds,
        paneShows prompt: PermissionPrompt? = F.box,
        planFile: PlanFile = .text("# Plan\n1. Do the thing", truncated: false)
    ) -> Rig {
        let recorder = Recorder()
        let model = PermissionCardModel(
            sendExpirySeconds: expiry,
            loadSessionContext: { _ in SessionContext(latestMessage: "The plan is ready.", planFile: nil) },
            loadPlanFile: { path in
                recorder.loaded(path)
                return planFile
            }
        )
        let source = PermissionFakeSource()
        if let prompt { source.screen = .screen(lines: F.screen(for: prompt), readAt: Date()) }
        model.statusSource = source
        model.onNotice = { recorder.notices.append($0) }
        model.onDecided = { recorder.decidedAgents.append($0) }
        model.onReleaseKeyboard = { recorder.releasedKeyboard += 1 }
        return Rig(model: model, source: source, recorder: recorder)
    }

    private func openReady(_ rig: Rig, _ prompt: PermissionPrompt = F.box) async {
        rig.model.open(F.agent("a", prompt))
        await waitUntil { rig.model.card?.plan?.phase == .ready && rig.model.card?.planFile != .loading }
    }

    // MARK: - Opening

    @Test func aPlanBoxOpensAPlanCardThatReadsThePaneTheTranscriptAndThePlanFile() async {
        let rig = makeRig()
        #expect(rig.model.open(F.agent("a")))
        #expect(rig.model.card?.plan?.phase == .checking)
        await waitUntil { rig.model.card?.plan?.phase == .ready && rig.model.card?.message != .loading && rig.model.card?.planFile != .loading }
        #expect(rig.model.card?.plan?.prompt == F.box)
        #expect(rig.model.card?.message == .text("The plan is ready."))
        #expect(rig.model.card?.planFile == .text("# Plan\n1. Do the thing", truncated: false))
        #expect(rig.recorder.loadedPaths == [F.planPath])
        #expect(rig.source.screenReads == 1)
        #expect(rig.source.planSent.isEmpty)
        #expect(rig.source.sent.isEmpty)
    }

    @Test func aToolBoxStillOpensTheOrdinaryCardWithNoPlanState() async {
        let rig = makeRig(paneShows: P.bash)
        rig.source.screen = .screen(lines: P.screen(for: P.bash), readAt: Date())
        rig.model.open(P.agent("a", P.bash))
        await waitUntil { rig.model.card?.state.phase == .ready }
        #expect(rig.model.card?.plan == nil)
        #expect(rig.recorder.loadedPaths.isEmpty)
    }

    @Test func aBoxWithNoPlanPathShowsThePlanLessCardWithoutReadingAnyFile() async {
        let box = PermissionPrompt(tool: "ExitPlanMode", detail: "", title: F.title, options: F.box.options, cursorIndex: 1, kind: .plan, planPath: nil)
        let rig = makeRig(paneShows: box)
        await openReady(rig, box)
        #expect(rig.model.card?.planFile == .noPath)
        #expect(rig.recorder.loadedPaths.isEmpty)
    }

    @Test func aMissingPlanFileNeverBlocksAnswering() async {
        let rig = makeRig(planFile: .unreadable("The plan file is not on this Mac: \(F.planPath)."))
        await openReady(rig)
        #expect(rig.model.card?.planFile == .unreadable("The plan file is not on this Mac: \(F.planPath)."))
        rig.model.handle(.digit(2))
        rig.model.handle(.enter)
        await rig.source.waitForPlanRequests(1)
        #expect(rig.source.planSent.map(\.index) == [2])
    }

    @Test func aHugePlanIsCarriedAsTruncated() async {
        let rig = makeRig(planFile: .text("# Big", truncated: true))
        await openReady(rig)
        #expect(rig.model.card?.planFile == .text("# Big", truncated: true))
    }

    @Test func whenThePaneNamesAnotherPlanFileThatFileIsRead() async {
        let rig = makeRig(paneShows: F.otherPlan)
        rig.model.open(F.agent("a", F.box))
        await waitUntil { rig.recorder.loadedPaths.count >= 2 }
        #expect(rig.recorder.loadedPaths == [F.planPath, F.otherPlan.planPath])
        #expect(rig.model.card?.plan?.changedNote == PermissionCardState.changedNoteText)
    }

    @Test func aPaneWithNoBoxMakesTheCardUnavailableAndNothingCanBeSent() async {
        let rig = makeRig(paneShows: nil)
        rig.source.screen = .screen(lines: ["$ ls"], readAt: Date())
        rig.model.open(F.agent("a"))
        await waitUntil { rig.model.card?.plan?.phase != .checking }
        #expect(rig.model.card?.plan?.phase == .unavailable(PermissionCardModel.notReadableMessage))
        rig.model.handle(.digit(1))
        rig.model.handle(.enter)
        await settleTasks()
        #expect(rig.source.planSent.isEmpty)
    }

    @Test func aToolBoxWhereAPlanBoxWasIsNeverAdoptedAndNeverAnswered() async {
        let rig = makeRig(paneShows: P.bash)
        rig.source.screen = .screen(lines: P.screen(for: P.bash), readAt: Date())
        rig.model.open(F.agent("a"))
        await waitUntil { rig.model.card?.plan?.phase != .checking }
        guard case .unavailable? = rig.model.card?.plan?.phase else {
            Issue.record("expected unavailable")
            return
        }
        rig.model.handle(.digit(1))
        rig.model.handle(.enter)
        await settleTasks()
        #expect(rig.source.planSent.isEmpty && rig.source.sent.isEmpty)
    }

    @Test func aPlanBoxWhereAToolBoxWasIsNeverAdoptedAndNeverAllowed() async {
        let rig = makeRig(paneShows: F.box)
        rig.model.open(P.agent("a", P.bash))
        await waitUntil { rig.model.card?.state.phase != .checking }
        guard case .unavailable? = rig.model.card?.state.phase else {
            Issue.record("expected unavailable")
            return
        }
        rig.model.handle(.digit(1))
        rig.model.handle(.enter)
        await settleTasks()
        #expect(rig.source.planSent.isEmpty && rig.source.sent.isEmpty)
    }

    // MARK: - Never a default

    @Test func returnWithNothingChosenSendsNothing() async {
        let rig = makeRig()
        await openReady(rig)
        rig.model.handle(.enter)
        rig.model.pressSend()
        await settleTasks()
        #expect(rig.source.planSent.isEmpty)
        #expect(rig.model.card != nil)
    }

    // MARK: - Choosing

    @Test func choosingManualApprovalSendsThatRowWithTheBoxAsThePaneShowsItAndClosesTheCard() async {
        let rig = makeRig()
        await openReady(rig)
        rig.model.handle(.digit(2))
        rig.model.handle(.enter)
        await rig.source.waitForPlanRequests(1)
        #expect(rig.source.planSent == [.init(paneId: "w1:a", index: 2, text: nil, permission: F.box)])
        #expect(rig.model.card == nil)
        #expect(rig.model.sendingLabel(for: F.agent("a")) == "Sending your answer…")
        rig.source.replyPlan(.sent(next: nil))
        await waitUntil { rig.recorder.decidedAgents == ["a"] }
        #expect(rig.recorder.decidedAgents == ["a"])
        #expect(rig.recorder.notices.isEmpty)
    }

    @Test func autoModeGoesOutOnlyOnTheSecondPress() async {
        let rig = makeRig()
        await openReady(rig)
        rig.model.handle(.digit(1))
        rig.model.handle(.enter)
        await settleTasks()
        #expect(rig.source.planSent.isEmpty)
        #expect(rig.model.card?.plan?.confirmText == "This puts the agent in auto mode — press again to confirm")
        rig.model.handle(.enter)
        await rig.source.waitForPlanRequests(1)
        #expect(rig.source.planSent.map(\.index) == [1])
    }

    @Test func feedbackIsTypedThenSentWithTheFeedbackRowAndItsText() async {
        let rig = makeRig()
        await openReady(rig)
        rig.model.handle(.digit(3))
        rig.model.handle(.enter)
        #expect(rig.model.card?.plan?.isTypingFeedback == true)
        rig.model.handle(.enter)   // still empty: nothing goes
        await settleTasks()
        #expect(rig.source.planSent.isEmpty)
        rig.model.setFeedbackText("Split step 2\nin two")
        rig.model.pressSend()
        await rig.source.waitForPlanRequests(1)
        #expect(rig.source.planSent == [.init(paneId: "w1:a", index: 3, text: "Split step 2 in two", permission: F.box)])
        #expect(rig.model.sendingLabel(for: F.agent("a")) == "Sending feedback…")
    }

    @Test func leavingTheFeedbackBoxHandsTheKeyboardBack() async {
        let rig = makeRig()
        await openReady(rig)
        rig.model.clickPlanOption(index: 3)
        rig.model.setFeedbackText("keep me")
        #expect(rig.model.card?.plan?.isTypingFeedback == true)
        rig.model.handle(.escape)
        #expect(rig.recorder.releasedKeyboard == 1)
        #expect(rig.model.card?.plan?.isTypingFeedback == false)
        #expect(rig.model.card?.plan?.feedbackText == "keep me")
        rig.model.handle(.escape)   // second Esc closes
        #expect(rig.model.card == nil)
    }

    // MARK: - The last look at the pane

    @Test func aBoxThatChangedAfterTheCardOpenedIsNotAnswered() async {
        let rig = makeRig()
        await openReady(rig)
        rig.source.screen = .screen(lines: F.screen(for: F.otherPlan), readAt: Date())   // another plan's box now
        rig.model.handle(.digit(2))
        rig.model.handle(.enter)
        await waitUntil { !rig.recorder.notices.isEmpty }
        #expect(rig.source.planSent.isEmpty)
        #expect(rig.recorder.notices == ["Plan answer not sent: \(PlanSend.promptChangedMessage)"])
        #expect(rig.model.sendingLabel(for: F.agent("a")) == nil)
    }

    @Test func aBoxThatIsGoneIsNotAnswered() async {
        let rig = makeRig()
        await openReady(rig)
        rig.source.screen = .screen(lines: ["$ "], readAt: Date())
        rig.model.handle(.digit(2))
        rig.model.handle(.enter)
        await waitUntil { !rig.recorder.notices.isEmpty }
        #expect(rig.source.planSent.isEmpty)
    }

    @Test func rewordedRowsAreNotAnswered() async {
        let rig = makeRig()
        await openReady(rig)
        rig.source.screen = .screen(lines: F.screen(for: F.bypassBox), readAt: Date())
        rig.model.handle(.digit(2))
        rig.model.handle(.enter)
        await waitUntil { !rig.recorder.notices.isEmpty }
        #expect(rig.source.planSent.isEmpty)
    }

    @Test func aPaneThatCannotBeReadAtSendTimeSendsNothingAndSaysSo() async {
        let rig = makeRig()
        await openReady(rig)
        rig.source.screen = .failure("Can't reach the status dashboard.")
        rig.model.handle(.digit(2))
        rig.model.handle(.enter)
        await waitUntil { !rig.recorder.notices.isEmpty }
        #expect(rig.source.planSent.isEmpty)
        #expect(rig.recorder.notices[0].contains("could not be checked first"))
    }

    // MARK: - Refusals and timeouts are never retried

    @Test func aRefusalShowsTheDashboardsWordsFreesTheRowAndIsNotRetried() async {
        let rig = makeRig()
        await openReady(rig)
        rig.model.handle(.digit(2))
        rig.model.handle(.enter)
        await rig.source.waitForPlanRequests(1)
        rig.source.replyPlan(.failed("permission prompt changed or gone — re-check the pane"))
        await waitUntil { !rig.recorder.notices.isEmpty }
        #expect(rig.recorder.notices == ["Plan answer not sent: permission prompt changed or gone — re-check the pane"])
        #expect(rig.model.sendingLabel(for: F.agent("a")) == nil)
        await settleTasks()
        #expect(rig.source.planSent.count == 1)
        #expect(rig.recorder.decidedAgents.isEmpty)
    }

    @Test func noReplyInTimeSaysItMayHaveGoneThroughAndNeverSendsAgain() async {
        let rig = makeRig(expiry: 0.05)
        await openReady(rig)
        rig.model.handle(.digit(2))
        rig.model.handle(.enter)
        await rig.source.waitForPlanRequests(1)
        await waitUntil { !rig.recorder.notices.isEmpty }
        #expect(rig.recorder.notices == [PermissionCardModel.noReplyMessage])
        #expect(rig.model.sendingLabel(for: F.agent("a")) == nil)
        await settleTasks()
        #expect(rig.source.planSent.count == 1)
    }

    @Test func aFeedbackRefusalKeepsNothingToResend() async {
        let rig = makeRig()
        await openReady(rig)
        rig.model.clickPlanOption(index: 3)
        rig.model.setFeedbackText("shorter please")
        rig.model.pressSend()
        await rig.source.waitForPlanRequests(1)
        rig.source.replyPlan(.failed("typed feedback did not land — re-check the pane"))
        await waitUntil { !rig.recorder.notices.isEmpty }
        #expect(rig.recorder.notices == ["Plan feedback not sent: typed feedback did not land — re-check the pane"])
        #expect(rig.model.card == nil)
    }

    @Test func aDashboardThatCannotAnswerPlansSaysSo() async {
        let rig = makeRig()
        await openReady(rig)
        rig.model.handle(.digit(2))
        rig.model.handle(.enter)
        await rig.source.waitForPlanRequests(1)
        rig.source.replyPlan(.unsupported("not found"))
        await waitUntil { !rig.recorder.notices.isEmpty }
        #expect(rig.recorder.notices[0].contains("may need a restart"))
    }

    @Test func aSecondPressWhileOneIsOnItsWayDoesNotSendTwice() async {
        let rig = makeRig()
        await openReady(rig)
        rig.model.handle(.digit(2))
        rig.model.handle(.enter)
        await rig.source.waitForPlanRequests(1)
        rig.model.open(F.agent("a"))   // the row cannot reopen while awaiting
        #expect(rig.model.card == nil)
        #expect(rig.source.planSent.count == 1)
    }
}
