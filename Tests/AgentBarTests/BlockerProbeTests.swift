import Foundation
import Testing
@testable import AgentBar

/// A status source that only serves pane screens: records every read and either answers at once
/// (from `replies`, the last one repeating) or, while `holds` is set, keeps them pending.
private final class ScreenReadSource: AgentStatusSource, @unchecked Sendable {
    let updates = AsyncStream<StatusSnapshot> { _ in }
    private let lock = NSLock()
    private var reads: [String] = []
    private var replies: [PaneScreenResult] = []
    private var held: [CheckedContinuation<PaneScreenResult, Never>] = []
    var holds = false

    var readPaneIds: [String] { lock.withLock { reads } }
    var heldCount: Int { lock.withLock { held.count } }

    func replyWith(_ results: PaneScreenResult...) { lock.withLock { replies = results } }

    func release(_ result: PaneScreenResult) {
        let continuation = lock.withLock { held.isEmpty ? nil : held.removeFirst() }
        continuation?.resume(returning: result)
    }

    func paneScreen(paneId: String) async -> PaneScreenResult {
        if holds {
            return await withCheckedContinuation { continuation in
                lock.withLock { reads.append(paneId); held.append(continuation) }
            }
        }
        return lock.withLock {
            reads.append(paneId)
            return replies.count > 1 ? replies.removeFirst() : (replies.first ?? .failure("no screen"))
        }
    }

    func focus(paneId: String) async -> FocusResult { .success }
    func answer(paneId: String, choice: AnswerChoice, question: QuestionIdentity) async -> AnswerResult { .failed("unused") }
    func perform(_ kind: SessionActionKind, rowId: String, confirmed: Bool) async -> SessionActionOutcome { .failed("unused") }
}

/// The Answer / Review button arriving with the "needs you" instead of seconds later: AgentBar reads
/// the pane itself when a row needs the user, against a fake source (no network).
@MainActor
struct BlockerProbeTests {
    typealias A = AnswerFixtures
    typealias F = AgentListFixtures

    private static let rule = String(repeating: "─", count: 90)
    private let questionScreen = PaneScreenResult.screen(lines: [rule, "  ☐ Fruit", "Which fruit?", "  ❯ 1. Apple", "    2. Banana", "    3. Type something.", rule], readAt: F.now)
    private let permissionScreen = PaneScreenResult.screen(lines: PermissionFixtures.screen(for: PermissionFixtures.bash), readAt: F.now)
    private let emptyScreen = PaneScreenResult.screen(lines: ["$ ls", "file.txt"], readAt: F.now)

    private struct Rig {
        let model: AgentPanelModel
        let source: ScreenReadSource
    }

    /// Retries run back to back: no real waiting, so a busy test run cannot make one late.
    private func makeRig(retryDelays: [TimeInterval] = [2, 5]) -> Rig {
        let defaults = makeScratchDefaults("blocker-probe")
        let model = AgentPanelModel(
            store: FrecencyStore(defaults: defaults), triageStore: TriageStore(defaults: defaults),
            blockerProbe: BlockerProbe(retryDelays: retryDelays, pause: { _ in await Task.yield() }), now: { F.now }
        )
        let source = ScreenReadSource()
        model.statusSource = source
        return Rig(model: model, source: source)
    }

    private func buttons(_ model: AgentPanelModel, _ id: String = "a") -> [RowButton] {
        model.presentation.agents.first { $0.id == id }.map(RowButtons.usableButtons) ?? []
    }

    private func needsYou(_ blocker: AgentBlocker?, id: String = "a") -> StatusSnapshot {
        F.snapshot([A.blockedAgent(id, blocker: blocker)])
    }

    // MARK: - Arrival

    @Test func aRowArrivingWithoutABlockerIsReadOnceAndAPickerOnItGetsItsAnswerButton() async {
        let rig = makeRig()
        rig.source.replyWith(questionScreen)
        rig.model.receive(needsYou(nil))
        #expect(buttons(rig.model) == [.park, .message, .moreActions])
        await waitUntil { buttons(rig.model) == [.answer, .park] }
        #expect(buttons(rig.model) == [.answer, .park])
        #expect(rig.source.readPaneIds == ["w1:a"])
        #expect(rig.model.presentation.agents.first?.blockedOnYou != nil)
    }

    @Test func aPermissionBoxOnAPlainBlockedRowGetsItsReviewButton() async {
        let rig = makeRig()
        rig.source.replyWith(permissionScreen)
        rig.model.receive(needsYou(.permission))
        #expect(buttons(rig.model) == [.openTerminal, .park])
        await waitUntil { buttons(rig.model) == [.review, .park] }
        #expect(buttons(rig.model) == [.review, .park])
    }

    @Test func aRowStillLoadingItsOptionsGetsTheAnswerButtonFromTheRead() async {
        let rig = makeRig()
        rig.source.replyWith(questionScreen)
        rig.model.receive(needsYou(.questionLoading(nil)))
        await waitUntil { buttons(rig.model) == [.answer, .park] }
        #expect(buttons(rig.model) == [.answer, .park])
    }

    @Test func aScreenWithNothingToAnswerLeavesTheRowAsItWas() async {
        let rig = makeRig()
        rig.source.replyWith(emptyScreen)
        rig.model.receive(needsYou(.permission))
        await waitUntil { rig.source.readPaneIds.count >= 3 }
        await settleTasks()
        #expect(buttons(rig.model) == [.openTerminal, .park])
        rig.source.replyWith(.failure("Can't reach the status dashboard."))
        rig.model.receive(needsYou(nil, id: "other"))
        await settleTasks()
        #expect(buttons(rig.model, "other") == [.park, .message, .moreActions])
    }

    @Test func aRowAlreadyParsedByTheDashboardIsNeverRead() async {
        let rig = makeRig()
        rig.model.receive(needsYou(.question(A.question())))
        rig.model.receive(F.snapshot([F.agent("w", section: .working), F.agent("p", section: .parked)]))
        await settleTasks()
        #expect(rig.source.readPaneIds.isEmpty)
    }

    // MARK: - One read, retries

    @Test func repeatedStatusUpdatesWhileAReadIsInFlightStartNoSecondRead() async {
        let rig = makeRig()
        rig.source.holds = true
        for _ in 0..<5 { rig.model.receive(needsYou(nil)) }
        await waitUntil { rig.source.heldCount == 1 }
        for _ in 0..<5 { rig.model.receive(needsYou(nil)) }
        await settleTasks()
        #expect(rig.source.readPaneIds == ["w1:a"])
    }

    @Test func aRowTheDashboardCallsBlockedIsReadAtMostThreeTimesThenLeftAlone() async {
        let rig = makeRig()
        rig.source.replyWith(emptyScreen)
        rig.model.receive(needsYou(.permission))
        await waitUntil { rig.source.readPaneIds.count >= 3 }
        for _ in 0..<5 { rig.model.receive(needsYou(.permission)) }
        await settleTasks()
        #expect(rig.source.readPaneIds.count == 3)
    }

    @Test func aRowTheDashboardIsSilentAboutIsReadOnce() async {
        let rig = makeRig()
        rig.source.replyWith(emptyScreen)
        rig.model.receive(needsYou(nil))
        await settleTasks()
        for _ in 0..<3 { rig.model.receive(needsYou(nil)) }
        await settleTasks()
        #expect(rig.source.readPaneIds.count == 1)
    }

    @Test func aBoxThatAppearsOnTheRetryIsPickedUp() async {
        let rig = makeRig()
        rig.source.replyWith(emptyScreen, permissionScreen)
        rig.model.receive(needsYou(.permission))
        await waitUntil { buttons(rig.model) == [.review, .park] }
        #expect(buttons(rig.model) == [.review, .park])
        #expect(rig.source.readPaneIds.count == 2)
    }

    @Test func anAgentThatLeavesAndComesBackIsReadAgain() async {
        let rig = makeRig()
        rig.source.replyWith(emptyScreen)
        rig.model.receive(needsYou(nil))
        await waitUntil { rig.source.readPaneIds.count == 1 }
        rig.model.receive(F.snapshot([A.blockedAgent("a", blocker: nil, section: .working)]))
        rig.model.receive(needsYou(nil))
        await waitUntil { rig.source.readPaneIds.count == 2 }
        #expect(rig.source.readPaneIds.count == 2)
    }

    // MARK: - Stale results

    @Test func aReadThatReturnsAfterTheAgentMovedOnIsDiscarded() async {
        let rig = makeRig()
        rig.source.holds = true
        rig.model.receive(needsYou(nil))
        await waitUntil { rig.source.heldCount == 1 }
        rig.model.receive(F.snapshot([A.blockedAgent("a", blocker: nil, section: .working)]))   // answered in its terminal
        rig.source.release(questionScreen)
        await settleTasks()
        rig.model.receive(needsYou(nil))
        #expect(buttons(rig.model) == [.park, .message, .moreActions])   // nothing was learned from the stale screen
    }

    @Test func aReadThatReturnsAfterTheDashboardCaughtUpChangesNothing() async {
        let rig = makeRig()
        rig.source.holds = true
        rig.model.receive(needsYou(nil))
        await waitUntil { rig.source.heldCount == 1 }
        let dashboardsOwn = A.question(question: "Which one, by the dashboard?")
        rig.model.receive(needsYou(.question(dashboardsOwn)))
        rig.source.release(questionScreen)
        await settleTasks()
        #expect(rig.model.presentation.agents.first?.blockedOnYou == .question(dashboardsOwn))
    }

    @Test func aReadForAnotherPaneIsNotAppliedToTheRow() async {
        let rig = makeRig()
        rig.source.holds = true
        rig.model.receive(needsYou(nil))
        await waitUntil { rig.source.heldCount == 1 }
        let moved = AgentSnapshot(
            id: "a", label: "agent a", projectName: nil, cwd: nil, paneId: "w9:z", section: .needsYou, statusText: "waiting",
            secondsInStatus: 1, hasUnpushedCommits: false, unpushedText: nil, promptExcerpt: nil, canFocus: true, hasHookData: true,
            rowId: "a", actions: .unknown
        )
        rig.model.receive(F.snapshot([moved]))
        rig.source.release(questionScreen)
        await settleTasks()
        #expect(buttons(rig.model) == [.park, .message, .moreActions])
    }
}
