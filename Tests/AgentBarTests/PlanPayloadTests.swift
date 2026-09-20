import Foundation
import Testing
@testable import AgentBar

/// How a plan-approval box reaches the panel: through the dashboard feed (`row.permission`), through
/// AgentBar's own pane read, and what the row then offers.
@MainActor
struct PlanPayloadTests {
    typealias F = PlanFixtures
    typealias A = AgentListFixtures

    private func snapshot(permissionField: Any?) throws -> StatusSnapshot {
        let data = StatusFixtures.data("state-healthy") { object in
            var computed = object["computed"] as! [String: Any]
            var rows = computed["needsYou"] as! [[String: Any]]
            if let permissionField { rows[1]["permission"] = permissionField }
            computed["needsYou"] = rows
            object["computed"] = computed
        }
        return try StatusSnapshotBuilder.snapshot(fromJSON: data, fetchedAt: StatusFixtures.serverNow)
    }

    private func blocker(_ snapshot: StatusSnapshot) throws -> AgentBlocker? {
        try #require(snapshot.agent(labelled: "agent-two")).blocker
    }

    // MARK: - The feed

    @Test func aPlanBoxInTheFeedMakesTheRowReviewableAsAPlan() throws {
        let object = try JSONSerialization.jsonObject(with: Data(F.json(F.box).utf8))
        #expect(try blocker(snapshot(permissionField: object)) == .permissionReview(F.box))
    }

    @Test func aPlanBoxWithNoFooterHasNoPlanPath() throws {
        let box = PermissionPrompt(tool: "ExitPlanMode", detail: "", title: F.title, options: F.box.options, cursorIndex: 1, kind: .plan, planPath: nil)
        let object = try JSONSerialization.jsonObject(with: Data(F.json(box).utf8))
        #expect(try blocker(snapshot(permissionField: object)) == .permissionReview(box))
    }

    @Test func aPlanBoxNeedsNoDetailButAToolBoxStillDoes() throws {
        let toolWithoutDetail: [String: Any] = [
            "tool": "ExitPlanMode", "title": F.title, "cursorIndex": 1,
            "options": [["index": 1, "label": "Yes"], ["index": 2, "label": "No"]],
        ]
        #expect(try blocker(snapshot(permissionField: toolWithoutDetail)) == .permission)   // no kind: not a plan
    }

    @Test func aPlanBoxMissingItsTitleOrRowsIsNotReviewable() throws {
        let broken: [[String: Any]] = [
            ["tool": "ExitPlanMode", "kind": "plan", "detail": NSNull(), "options": [["index": 1, "label": "Yes"], ["index": 2, "label": "No"]]],
            ["tool": "ExitPlanMode", "kind": "plan", "detail": NSNull(), "title": F.title, "options": [["index": 1, "label": "Yes"]]],
        ]
        for permission in broken {
            #expect(try blocker(snapshot(permissionField: permission)) == .permission, "\(permission)")
        }
    }

    @Test func aReplyNamingAnotherPlanBoxAsNextDecodesAsAPlan() throws {
        let reply = #"{"ok": true, "next": \#(F.json(F.otherPlan))}"#
        #expect(DashboardPermissionResponse.result(body: Data(reply.utf8), statusCode: 200) == .sent(next: F.otherPlan))
    }

    // MARK: - The row's button

    @Test func aReviewablePlanRowShowsReviewAndParkNotOpenTerminal() {
        let agent = F.agent("a")
        #expect(RowButtons.usableButtons(for: agent) == [.review, .park])
    }

    @Test func aPlainBlockedRowStillShowsOpenTerminal() {
        let agent = PermissionFixtures.agent("a", nil)
        #expect(RowButtons.usableButtons(for: agent) == [.openTerminal, .park])
    }

    @Test func aParkedPlanRowKeepsTheUnparkButtons() {
        #expect(RowButtons.usableButtons(for: F.agent("a").placed(in: .parked)) == [.unpark, .done])
    }

    @Test func aPlanRowNeverOffersMessage() {
        #expect(!RowButtons.usableButtons(for: F.agent("a")).contains(.message))
    }

    // MARK: - AgentBar's own pane read

    @Test func aPlanBoxOnAPlainBlockedRowGetsItsReviewButtonFromThePaneRead() async {
        let defaults = makeScratchDefaults("plan-probe")
        let model = AgentPanelModel(
            store: FrecencyStore(defaults: defaults), triageStore: TriageStore(defaults: defaults),
            blockerProbe: BlockerProbe(retryDelays: [], pause: { _ in await Task.yield() }), now: { A.now }
        )
        let source = PermissionFakeSource()
        source.screen = .screen(lines: F.screen(for: F.box), readAt: A.now)
        model.statusSource = source
        model.receive(A.snapshot([AnswerFixtures.blockedAgent("a", blocker: .permission)]))
        func buttons() -> [RowButton] { model.presentation.agents.first.map(RowButtons.usableButtons) ?? [] }
        #expect(buttons() == [.openTerminal, .park])
        await waitUntil { buttons() == [.review, .park] }
        #expect(buttons() == [.review, .park])
        #expect(model.presentation.agents.first?.blockedOnYou?.permissionPrompt?.kind == .plan)
    }

    // MARK: - The panel

    @Test func reviewOnAPlanRowOpensThePlanCardAndDigitsKeysAndTheHintsFollowIt() async {
        let defaults = makeScratchDefaults("plan-panel")
        let permission = PermissionCardModel(loadSessionContext: { _ in .empty }, loadPlanFile: { _ in .text("# P", truncated: false) })
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
        #expect(model.permission.card?.plan != nil)
        #expect(model.isCardOpen)
        await waitUntil { model.permission.card?.hintMode == .choosing }
        model.handleCardDigit(1)
        #expect(model.permission.card?.hintMode == .chosen)
        model.activateSelected()   // Return: first press of the auto-mode row
        #expect(model.permission.card?.hintMode == .confirmingPrivilege)
        await settleTasks()
        #expect(source.planSent.isEmpty)
        model.handleCardStrayKey()   // any other key cancels
        #expect(model.permission.card?.hintMode == .chosen)
        #expect(model.backOutOfButtons())   // Esc with nothing pending: back to the list
        #expect(model.permission.card == nil)
    }
}
