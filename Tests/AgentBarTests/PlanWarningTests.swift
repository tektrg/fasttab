import Foundation
import Testing
@testable import AgentBar

private let planWarningText = "pane shows 'auto mode on' after choosing option 3"

/// The dashboard's optional `warning` on an ok plan `select` reply (the pane shows auto mode after a choice
/// that was not auto mode): decoded, and always shown to the user (footer, and the plan card if one is open).
@MainActor
struct PlanWarningTests {
    typealias F = PlanFixtures
    typealias A = AgentListFixtures

    private let endpoint = DashboardEndpoint(baseURL: URL(string: "http://127.0.0.1:4799")!)

    private func decode(_ json: String, status: Int = 200) -> PermissionResult {
        DashboardPermissionResponse.result(body: Data(json.utf8), statusCode: status)
    }

    // MARK: - Decoding

    @Test func anOkReplyWithAWarningCarriesIt() {
        #expect(decode(#"{"ok": true, "next": null, "warning": "\#(planWarningText)"}"#) == .sent(next: nil, warning: planWarningText))
    }

    @Test func anOkReplyWithoutAWarningCarriesNone() {
        #expect(decode(#"{"ok": true, "next": null}"#) == .sent(next: nil, warning: nil))
    }

    @Test func aBlankOrNullWarningIsNoWarning() {
        #expect(decode(#"{"ok": true, "next": null, "warning": ""}"#) == .sent(next: nil, warning: nil))
        #expect(decode(#"{"ok": true, "next": null, "warning": "  \n"}"#) == .sent(next: nil, warning: nil))
        #expect(decode(#"{"ok": true, "next": null, "warning": null}"#) == .sent(next: nil, warning: nil))
    }

    @Test func aWarningThatIsNotAStringIsStillTold() {
        #expect(decode(#"{"ok": true, "next": null, "warning": true}"#)
            == .sent(next: nil, warning: DashboardPermissionResponse.unreadableWarning))
        #expect(decode(#"{"ok": true, "next": null, "warning": {"a": 1}}"#)
            == .sent(next: nil, warning: DashboardPermissionResponse.unreadableWarning))
    }

    @Test func theWarningIsTrimmedAndRidesAlongsideANextBox() {
        let reply = #"{"ok": true, "next": \#(F.json(F.otherPlan)), "warning": "  auto mode on\n"}"#
        #expect(decode(reply) == .sent(next: F.otherPlan, warning: "auto mode on"))
    }

    @Test func aRefusalIgnoresAnyWarning() {
        #expect(decode(#"{"ok": false, "error": "nope", "warning": "x"}"#) == .failed("nope"))
    }

    @Test func aWarningComesThroughTheSource() async {
        let transport = ScriptedDashboardTransport { _ in
            .body(Data(#"{"ok": true, "next": null, "warning": "\#(planWarningText)"}"#.utf8), statusCode: 200)
        }
        let source = DashboardStatusSource(endpoint: endpoint, transport: transport)
        let result = await source.selectPlanOption(paneId: "w1:p1", index: 3, text: "more", permission: F.box)
        #expect(result == .sent(next: nil, warning: planWarningText))
        #expect(transport.requests.count == 1)
    }

    // MARK: - The wording

    @Test func theSentenceNamesAutoModeQuotesTheDashboardAndSendsYouToTheTerminal() {
        #expect(PlanSend.autoModeWarningSentence("pane shows auto mode.")
            == "Sent, but the agent now shows auto mode: pane shows auto mode. Check the terminal.")
        #expect(PlanSend.autoModeWarningSentence(planWarningText)
            == "Sent, but the agent now shows auto mode: \(planWarningText). Check the terminal.")
    }

    @Test func theFeedbackNoteSaysItIsFeedbackAndThePaneStaysInPlanMode() {
        #expect(PlanCardState.feedbackNote.contains("feedback"))
        #expect(PlanCardState.feedbackNote.contains("stays in plan mode"))
        #expect(PlanCardState.feedbackTooLongNote.contains("\(PlanCardState.feedbackMaxCharacters)"))
    }

    // MARK: - The card model

    private final class Recorder: @unchecked Sendable {
        var notices: [String] = []
        var warnings: [String] = []
        var decided: [String] = []
    }

    private func makeModel(expiry: TimeInterval = PermissionSendTracker.expirySeconds) -> (PermissionCardModel, PermissionFakeSource, Recorder) {
        let recorder = Recorder()
        let model = PermissionCardModel(
            sendExpirySeconds: expiry,
            loadSessionContext: { _ in SessionContext(latestMessage: "The plan is ready.", planFile: nil) },
            loadPlanFile: { _ in .text("# Plan", truncated: false) }
        )
        let source = PermissionFakeSource()
        source.screen = .screen(lines: F.screen(for: F.box), readAt: Date())
        model.statusSource = source
        model.onNotice = { recorder.notices.append($0) }
        model.onWarning = { recorder.warnings.append($0) }
        model.onDecided = { recorder.decided.append($0) }
        return (model, source, recorder)
    }

    private func sendFeedback(_ model: PermissionCardModel, _ source: PermissionFakeSource) async {
        model.open(F.agent("a"))
        await waitUntil { model.card?.plan?.phase == .ready && model.card?.planFile != .loading }
        model.handle(.digit(3))
        model.handle(.enter)
        model.setFeedbackText("please also add a second file")
        model.pressSend()
        await source.waitForPlanRequests(1)
    }

    @Test func aWarningOnASentFeedbackIsShownAsAWarningNotAFailure() async {
        let (model, source, recorder) = makeModel()
        await sendFeedback(model, source)
        source.replyPlan(.sent(next: nil, warning: planWarningText))
        await waitUntil { !recorder.warnings.isEmpty }
        #expect(recorder.warnings == ["Sent, but the agent now shows auto mode: \(planWarningText). Check the terminal."])
        #expect(recorder.notices.isEmpty)
        #expect(recorder.decided == ["a"])   // the send itself still counts as sent
    }

    @Test func noWarningShowsNothing() async {
        let (model, source, recorder) = makeModel()
        await sendFeedback(model, source)
        source.replyPlan(.sent(next: nil))
        await waitUntil { !recorder.decided.isEmpty }
        #expect(recorder.warnings.isEmpty && recorder.notices.isEmpty)
    }

    @Test func aPlanCardOpenForTheSameAgentCarriesTheWarningToo() async {
        // No reply within the wait frees the row; the user opens the (revised) plan's card; then the late reply lands.
        let (model, source, recorder) = makeModel(expiry: 0.05)
        await sendFeedback(model, source)
        #expect(model.card == nil)
        await waitUntil { !recorder.notices.isEmpty }
        model.open(F.agent("a"))
        await waitUntil { model.card?.plan?.phase == .ready }
        source.replyPlan(.sent(next: nil, warning: planWarningText))
        await waitUntil { model.card?.sentWarning != nil }
        #expect(model.card?.sentWarning == "Sent, but the agent now shows auto mode: \(planWarningText). Check the terminal.")
        #expect(recorder.warnings.count == 1)   // told in the footer as well, even though the send record had expired
    }

    @Test func aCardOpenForAnotherAgentIsLeftAlone() async {
        let (model, source, recorder) = makeModel()
        await sendFeedback(model, source)
        model.open(F.agent("b"))
        await waitUntil { model.card?.plan?.phase == .ready }
        source.replyPlan(.sent(next: nil, warning: planWarningText))
        await waitUntil { !recorder.warnings.isEmpty }
        #expect(model.card?.sentWarning == nil)
    }

    // MARK: - The panel's footer

    @Test func thePanelShowsTheWarningInTheFooterOrangeAndClosableAndEscClearsIt() async {
        let defaults = makeScratchDefaults("plan-warning")
        let permission = PermissionCardModel(loadSessionContext: { _ in .empty }, loadPlanFile: { _ in .text("# Plan", truncated: false) })
        let model = AgentPanelModel(
            store: FrecencyStore(defaults: defaults), triageStore: TriageStore(defaults: defaults),
            answer: AnswerCardModel(loadSessionContext: { _ in .empty }, openFile: { _ in }),
            permission: permission, now: { A.now }
        )
        let source = PermissionFakeSource()
        source.screen = .screen(lines: F.screen(for: F.box), readAt: A.now)
        model.statusSource = source
        model.receive(A.snapshot([F.agent("a")]))
        model.press(.review, on: "a")
        await waitUntil { permission.card?.plan?.phase == .ready }
        permission.handle(.digit(2))
        model.activateSelected()
        await source.waitForPlanRequests(1)
        source.replyPlan(.sent(next: nil, warning: planWarningText))
        await waitUntil { model.footerNotice != nil }
        let expected = PanelFooterNotice.warning("Sent, but the agent now shows auto mode: \(planWarningText). Check the terminal.")
        #expect(model.footerNotice == expected)
        #expect(expected.isDismissible)
        #expect(expected.text.hasPrefix("Sent, but the agent now shows auto mode"))
        #expect(model.dismissFooterNotice())
        #expect(model.footerNotice == nil)
    }

    @Test func aPlainSendLeavesTheFooterEmpty() async {
        let defaults = makeScratchDefaults("plan-no-warning")
        let permission = PermissionCardModel(loadSessionContext: { _ in .empty }, loadPlanFile: { _ in .text("# Plan", truncated: false) })
        let model = AgentPanelModel(
            store: FrecencyStore(defaults: defaults), triageStore: TriageStore(defaults: defaults),
            answer: AnswerCardModel(loadSessionContext: { _ in .empty }, openFile: { _ in }),
            permission: permission, now: { A.now }
        )
        let source = PermissionFakeSource()
        source.screen = .screen(lines: F.screen(for: F.box), readAt: A.now)
        model.statusSource = source
        model.receive(A.snapshot([F.agent("a")]))
        model.press(.review, on: "a")
        await waitUntil { permission.card?.plan?.phase == .ready }
        permission.handle(.digit(2))
        model.activateSelected()
        await source.waitForPlanRequests(1)
        source.replyPlan(.sent(next: nil))
        await settleTasks()
        #expect(model.footerNotice == nil)
    }
}
