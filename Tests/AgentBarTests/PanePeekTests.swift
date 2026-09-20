import Foundation
import Testing
@testable import AgentBar

/// A status source whose screen reads stay pending until the test answers them.
private final class ScreenFakeSource: AgentStatusSource, @unchecked Sendable {
    let updates = AsyncStream<StatusSnapshot> { _ in }
    private let lock = NSLock()
    private var requested: [String] = []
    private var pending: [CheckedContinuation<PaneScreenResult, Never>] = []

    var requestedPaneIds: [String] { lock.withLock { requested } }
    var pendingCount: Int { lock.withLock { pending.count } }

    func focus(paneId: String) async -> FocusResult { .success }
    func answer(paneId: String, choice: AnswerChoice, question: QuestionIdentity) async -> AnswerResult { .failed("unused") }
    func perform(_ kind: SessionActionKind, rowId: String, confirmed: Bool) async -> SessionActionOutcome { .failed("unused") }

    func paneScreen(paneId: String) async -> PaneScreenResult {
        await withCheckedContinuation { continuation in
            lock.withLock {
                requested.append(paneId)
                pending.append(continuation)
            }
        }
    }

    func answerOldest(with result: PaneScreenResult) {
        let continuation = lock.withLock { pending.isEmpty ? nil : pending.removeFirst() }
        continuation?.resume(returning: result)
    }
}

@MainActor
struct PanePeekTests {
    typealias F = AgentListFixtures

    private static let readAt = Date(timeIntervalSince1970: 1_800_000_100)

    /// "a" is blocked on something the panel does not read (terminal only), so the blocker
    /// probe (which reads the screens of needs-you rows) leaves it alone and only peeks read.
    private let snapshot = F.snapshot([
        F.agent("a", label: "alpha", project: "proj", section: .needsYou).withBlocker(.questionNotAnswerable),
        F.agent("b", label: "beta", section: .working),
        F.agent("noPane", label: "orphan", section: .working)
    ])

    private func makeRig() -> (model: AgentPanelModel, source: ScreenFakeSource) {
        let suite = "AgentBarTests.\(UUID().uuidString)"
        let model = AgentPanelModel(store: FrecencyStore(defaults: UserDefaults(suiteName: suite)!), now: { F.now })
        let source = ScreenFakeSource()
        model.statusSource = source
        model.receive(snapshot)
        return (model, source)
    }

    /// Lets the model's screen-read task run until it has issued its request.
    private func waitForRequests(_ source: ScreenFakeSource, count: Int) async {
        for _ in 0..<200 where source.pendingCount < count { await Task.yield() }
    }

    private func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }

    // MARK: - Opening

    @Test func spaceWithEmptySearchOpensALoadingPeekOnTheSelectedAgent() async {
        let (model, source) = makeRig()
        #expect(model.togglePeek())
        #expect(model.peek == PanePeek(agentID: "a", label: "alpha", projectName: "proj", content: .loading))
        await waitForRequests(source, count: 1)
        #expect(source.requestedPaneIds == ["w1:a"])
    }

    @Test func spaceWithTextInTheSearchIsNotUsedSoTheFieldTypesIt() {
        let (model, _) = makeRig()
        model.query = "alp"
        #expect(model.togglePeek() == false)
        #expect(model.peek == nil)
    }

    @Test func spaceWithNothingSelectedDoesNothing() {
        let (model, _) = makeRig()
        model.receive(F.snapshot([], health: .down(reason: "x"), boardIsCurrent: false))
        model.togglePeek()
        #expect(model.peek == nil)
    }

    @Test func anAgentWithoutAPaneShowsTheEndedMessageAndReadsNothing() async {
        let suite = "AgentBarTests.\(UUID().uuidString)"
        let model = AgentPanelModel(store: FrecencyStore(defaults: UserDefaults(suiteName: suite)!), now: { F.now })
        let source = ScreenFakeSource()
        model.statusSource = source
        var paneless = F.agent("ghost", label: "ghost", section: .working)
        paneless = AgentSnapshot(
            id: paneless.id, label: paneless.label, projectName: nil, cwd: nil, paneId: nil, section: .working,
            statusText: "", secondsInStatus: nil, hasUnpushedCommits: false, unpushedText: nil,
            promptExcerpt: nil, canFocus: true, hasHookData: true
        )
        model.receive(F.snapshot([paneless]))
        model.togglePeek()
        #expect(model.peek?.content == .unavailable(PanePeek.endedAgentMessage))
        await settle()
        #expect(source.requestedPaneIds.isEmpty)
    }

    @Test func withoutAStatusSourceThePeekSaysSo() {
        let (model, _) = makeRig()
        model.statusSource = nil
        model.togglePeek()
        #expect(model.peek?.content == .unavailable(PanePeek.noSourceMessage))
    }

    // MARK: - Results

    @Test func loadingBecomesTheCleanedScreen() async {
        let (model, source) = makeRig()
        model.togglePeek()
        await waitForRequests(source, count: 1)
        source.answerOldest(with: .screen(lines: ["\u{1B}[31mhello\u{1B}[0m", "", ""], readAt: Self.readAt))
        await settle()
        #expect(model.peek?.content == .screen(lines: ["hello"], readAt: Self.readAt))
    }

    @Test func aFailureBecomesAPlainMessage() async {
        let (model, source) = makeRig()
        model.togglePeek()
        await waitForRequests(source, count: 1)
        source.answerOldest(with: .failure("Can't reach the status dashboard."))
        await settle()
        #expect(model.peek?.content == .unavailable("Can't reach the status dashboard."))
    }

    @Test func aBlankScreenBecomesAMessageNotABlankPanel() async {
        let (model, source) = makeRig()
        model.togglePeek()
        await waitForRequests(source, count: 1)
        source.answerOldest(with: .screen(lines: ["  ", ""], readAt: Self.readAt))
        await settle()
        #expect(model.peek?.content == .unavailable(PanePeek.blankScreenMessage))
    }

    // MARK: - Closing and stale results

    @Test func spaceAgainClosesThePeek() async {
        let (model, source) = makeRig()
        model.togglePeek()
        await waitForRequests(source, count: 1)
        #expect(model.togglePeek())
        #expect(model.peek == nil)
    }

    @Test func aResultArrivingAfterClosingIsIgnored() async {
        let (model, source) = makeRig()
        model.togglePeek()
        await waitForRequests(source, count: 1)
        model.closePeek()
        source.answerOldest(with: .screen(lines: ["late"], readAt: Self.readAt))
        await settle()
        #expect(model.peek == nil)
    }

    @Test func aResultForAnAgentTheSelectionMovedAwayFromIsIgnored() async {
        let (model, source) = makeRig()
        model.togglePeek()
        await waitForRequests(source, count: 1)
        model.moveSelection(by: 1)
        #expect(model.peek == nil)
        source.answerOldest(with: .screen(lines: ["stale"], readAt: Self.readAt))
        await settle()
        #expect(model.peek == nil)
    }

    @Test func aStaleResultNeverLandsOnANewerPeek() async {
        let (model, source) = makeRig()
        model.togglePeek()                       // alpha, request 1
        await waitForRequests(source, count: 1)
        model.moveSelection(by: 1)               // closes it
        model.togglePeek()                       // beta, request 2
        await waitForRequests(source, count: 2)
        source.answerOldest(with: .screen(lines: ["from alpha"], readAt: Self.readAt))
        await settle()
        #expect(model.peek?.content == .loading)
        source.answerOldest(with: .screen(lines: ["from beta"], readAt: Self.readAt))
        await settle()
        #expect(model.peek?.content == .screen(lines: ["from beta"], readAt: Self.readAt))
        #expect(model.peek?.agentID == "b")
    }

    @Test func movingTheSelectionTypingHoverReopenAndANewDashboardAllClosePeek() {
        let (model, _) = makeRig()
        model.togglePeek()
        model.moveSelection(by: 1)
        #expect(model.peek == nil)

        model.togglePeek()
        model.select(agentID: "a")
        #expect(model.peek == nil)

        model.togglePeek()
        model.query = "b"
        #expect(model.peek == nil)

        model.query = ""
        model.togglePeek()
        model.resetForShow()
        #expect(model.peek == nil)

        model.togglePeek()
        model.useDashboard(address: "127.0.0.1:9")
        #expect(model.peek == nil)
    }

    @Test func hoveringTheAlreadySelectedRowKeepsThePeek() {
        let (model, _) = makeRig()
        model.togglePeek()
        model.select(agentID: "a")
        #expect(model.peek != nil)
    }

    @Test func aRefreshKeepsThePeekWhileTheAgentStaysSelectedElseClosesIt() {
        let (model, _) = makeRig()
        model.togglePeek()
        model.receive(snapshot)
        #expect(model.peek != nil)
        model.receive(F.snapshot([F.agent("b", section: .working)]))
        #expect(model.peek == nil)
    }

    // MARK: - No polling

    @Test func onePeekIsExactlyOneScreenRequestEvenAsFeedUpdatesArrive() async {
        let (model, source) = makeRig()
        model.togglePeek()
        await waitForRequests(source, count: 1)
        for _ in 0..<5 { model.receive(snapshot) }
        source.answerOldest(with: .screen(lines: ["x"], readAt: Self.readAt))
        await settle()
        for _ in 0..<5 { model.receive(snapshot) }
        await settle()
        #expect(source.requestedPaneIds == ["w1:a"])
    }
}
