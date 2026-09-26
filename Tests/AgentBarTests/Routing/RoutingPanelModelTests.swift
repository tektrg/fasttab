import Foundation
import Testing
@testable import AgentBar

/// Shift+Return routing as `AgentPanelModel` drives it: candidate building, the confirm-first /
/// send-immediately settings, Esc, and the sticky row note — against fake Jev and dashboard
/// sources. Nothing here touches a real network or Keychain.
@MainActor
struct RoutingPanelModelTests {
    typealias F = AgentListFixtures

    private final class FakeKeyStore: RoutingAPIKeyStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var key: String?
        init(key: String?) { self.key = key }
        func get() -> String? { lock.withLock { key } }
        func set(_ key: String?) throws { lock.withLock { self.key = key } }
    }

    private struct Rig {
        let model: AgentPanelModel
        let client: FakeJevRoutingClient
        let source: MessageFakeSource
    }

    private func makeRig(
        apiKey: String? = "sk-test",
        agents: [AgentSnapshot] = [F.agent("w", label: "worker", section: .working)],
        afterRouting: AfterRoutingBehavior = .confirmFirst
    ) -> Rig {
        let defaults = makeScratchDefaults("routing-panel-\(UUID().uuidString)")
        let model = AgentPanelModel(
            store: FrecencyStore(defaults: defaults),
            triageStore: TriageStore(defaults: defaults),
            routedNoteStore: RoutedNoteStore(defaults: defaults),
            now: { F.now }
        )
        let source = MessageFakeSource()
        model.statusSource = source
        model.routingAPIKeyStore = FakeKeyStore(key: apiKey)
        model.applyRouting(RoutingSettings(modelID: "~typesafe/jev-latest", afterRouting: afterRouting))
        let client = FakeJevRoutingClient()
        model.makeRoutingClient = { _, _, _ in client }
        model.receive(F.snapshot(agents))
        return Rig(model: model, client: client, source: source)
    }

    // MARK: - Starting a route

    @Test func startRoutingDoesNothingWithAnEmptyBox() {
        let rig = makeRig()
        rig.model.startRouting()
        #expect(rig.model.routingState == nil)
        #expect(rig.client.calls.isEmpty)
    }

    @Test func startRoutingDoesNothingWhileACardIsOpen() {
        let rig = makeRig(agents: [F.agent("w", label: "worker", section: .working, statusText: "waiting")])
        rig.model.query = "hello"
        #expect(rig.model.message.open(F.agent("w", label: "worker", section: .working)))
        rig.model.startRouting()
        #expect(rig.client.calls.isEmpty)
    }

    @Test func withNoAPIKeyItFailsFastWithNoNetworkCall() {
        let rig = makeRig(apiKey: nil)
        rig.model.query = "fix the login timeout"
        rig.model.startRouting()
        #expect(rig.model.routingState == nil)
        #expect(rig.client.calls.isEmpty)
        #expect(rig.model.footerNotice?.text.contains("Settings > Routing") == true)
    }

    /// Zero message-eligible agents shown = zero candidates (the real `OpenRouterJevClient.route`
    /// then returns `.none` without a network call; the "start a new worker" candidates that used
    /// to fill this gap were retired 2026-09-25). Either way the route must resolve to a clear
    /// notice rather than sitting on `.loading` or silently picking something.
    @Test func withNoMessageEligibleAgentsRoutingResolvesToNoneRatherThanPickingAnything() async {
        let rig = makeRig(agents: [F.agent("e", section: .ended)])
        rig.model.query = "fix the login timeout"
        rig.model.startRouting()
        await waitUntil { rig.model.routingState == nil }
        #expect(rig.client.calls.first?.candidateIDs.isEmpty == true)
        #expect(rig.model.footerNotice?.text == "No agent can take a message right now.")
    }

    @Test func onlyMessageEligibleAgentsAreOfferedAsLiveCandidates() async {
        let rig = makeRig(agents: [
            F.agent("w", label: "worker", section: .working),
            F.agent("e", section: .ended),
        ])
        rig.client.outcome = .picked(agentID: "w", confidence: 0.9)
        rig.model.query = "fix it"
        rig.model.startRouting()
        #expect(rig.model.routingState == .loading)
        await waitUntil { rig.model.routingState != .loading }
        #expect(rig.client.calls.first?.candidateIDs == ["w"])
        #expect(rig.client.calls.first?.text == "fix it")
    }

    // MARK: - Confirm-first

    @Test func aPickWaitsForAConfirmingReturnByDefault() async {
        let rig = makeRig(afterRouting: .confirmFirst)
        rig.client.outcome = .picked(agentID: "w", confidence: 0.87)
        rig.model.query = "fix the login timeout"
        rig.model.startRouting()
        await waitUntil { rig.model.routingState != .loading }
        #expect(rig.model.routingState == .confirming(agentID: "w", label: "worker", confidence: 0.87))
        #expect(rig.source.sent.isEmpty)   // nothing sent until confirmed
    }

    @Test func returnWhileConfirmingSendsAndClearsTheBox() async {
        let rig = makeRig(afterRouting: .confirmFirst)
        rig.client.outcome = .picked(agentID: "w", confidence: 0.9)
        rig.model.query = "fix the login timeout"
        rig.model.startRouting()
        await waitUntil { rig.model.routingState != .loading }
        rig.model.activateSelected()
        #expect(rig.model.routingState == nil)
        #expect(rig.model.query == "")
        await rig.source.waitForRequests(1)
        #expect(rig.source.sent == [.init(rowId: "w", text: "fix the login timeout", confirmed: true)])
    }

    @Test func escWhileConfirmingCancelsAndKeepsTheTypedText() async {
        let rig = makeRig(afterRouting: .confirmFirst)
        rig.client.outcome = .picked(agentID: "w", confidence: 0.9)
        rig.model.query = "fix the login timeout"
        rig.model.startRouting()
        await waitUntil { rig.model.routingState != .loading }
        #expect(rig.model.backOutOfButtons())
        #expect(rig.model.routingState == nil)
        #expect(rig.model.query == "fix the login timeout")
        #expect(rig.source.sent.isEmpty)
    }

    /// Regression: while "Asking Jev…" is showing, a plain Return used to fall through to the
    /// normal activate/switch path (nothing special-cased `.loading`, only `.confirming`) and fire
    /// an unrelated action — pressing whatever row was highlighted / switching to the selected
    /// agent — while the user was just waiting on Jev.
    @Test func returnWhileLoadingIsSwallowedAndDoesNotActivateTheSelectedAgent() {
        let rig = makeRig()
        var activated: [String] = []
        rig.model.onActivate = { activated.append($0.id) }
        rig.model.query = "fix the login timeout"
        rig.model.startRouting()
        #expect(rig.model.routingState == .loading)
        rig.model.activateSelected()
        #expect(activated.isEmpty)   // the normal activate/switch path never fired
        #expect(rig.model.routingState == .loading)   // still waiting on Jev, untouched
        #expect(rig.model.query == "fix the login timeout")   // typed text is not lost
    }

    /// Regression: `activate(agentID:)` is the mouse-click path (`AgentListView`'s `.onTapGesture`),
    /// a second, independent entry point from `activateSelected`'s keyboard Return. It had no
    /// routing guard at all, so clicking any row while "Asking Jev…" showed immediately switched
    /// to/activated the clicked agent — the same surprising mid-route side effect the Return guard
    /// was built to prevent, just reachable via mouse instead of keyboard.
    @Test func clickWhileLoadingIsSwallowedAndDoesNotActivateTheClickedAgent() {
        let rig = makeRig()
        var activated: [String] = []
        rig.model.onActivate = { activated.append($0.id) }
        rig.model.query = "fix the login timeout"
        rig.model.startRouting()
        #expect(rig.model.routingState == .loading)
        rig.model.activate(agentID: "w")
        #expect(activated.isEmpty)   // the click never fired activate/switch
        #expect(rig.model.routingState == .loading)   // still waiting on Jev, untouched
    }

    @Test func escWhileLoadingCancelsAndDropsTheLateReply() async {
        let rig = makeRig(afterRouting: .confirmFirst)
        rig.model.query = "fix the login timeout"
        rig.model.startRouting()
        #expect(rig.model.routingState == .loading)
        #expect(rig.model.backOutOfButtons())
        #expect(rig.model.routingState == nil)
        rig.client.outcome = .picked(agentID: "w", confidence: 0.9)
        // the in-flight call from before cancelling still resolves; it must not resurrect the route
        try? await Task.sleep(for: .milliseconds(50))
        #expect(rig.model.routingState == nil)
        #expect(rig.source.sent.isEmpty)
    }

    // MARK: - Typing after Shift+Return never changes what gets sent

    @Test func editingTheBoxAfterShiftReturnDoesNotChangeWhatIsSent() async {
        let rig = makeRig(afterRouting: .confirmFirst)
        rig.client.outcome = .picked(agentID: "w", confidence: 0.9)
        rig.model.query = "fix the login timeout"
        rig.model.startRouting()
        rig.model.query = "something completely different"   // the box is not locked
        await waitUntil { rig.model.routingState != .loading }
        rig.model.activateSelected()
        await rig.source.waitForRequests(1)
        #expect(rig.source.sent.first?.text == "fix the login timeout")
    }

    // MARK: - Send immediately

    @Test func sendImmediatelySkipsConfirmationAndSendsAtOnce() async {
        let rig = makeRig(afterRouting: .sendImmediately)
        rig.client.outcome = .picked(agentID: "w", confidence: 0.95)
        rig.model.query = "fix the login timeout"
        rig.model.startRouting()
        await rig.source.waitForRequests(1)
        #expect(rig.model.routingState == nil)
        #expect(rig.source.sent == [.init(rowId: "w", text: "fix the login timeout", confirmed: true)])
    }

    // MARK: - Failures

    @Test func anUnknownPickedAgentShowsANoticeAndSendsNothing() async {
        let rig = makeRig()
        rig.client.outcome = .picked(agentID: "not-a-real-agent", confidence: 0.9)
        rig.model.query = "fix it"
        rig.model.startRouting()
        await waitUntil { rig.model.routingState == nil }
        #expect(rig.model.footerNotice != nil)
        #expect(rig.source.sent.isEmpty)
    }

    /// A picked id that names a real, currently-shown agent that was never itself a candidate
    /// (never trust the client's echo blindly) must be rejected exactly like an unknown one —
    /// not treated as a valid pick just because the id happens to exist.
    @Test func aPickedAgentThatExistsButWasNeverACandidateShowsANoticeAndSendsNothing() async {
        let rig = makeRig(agents: [
            F.agent("w", label: "worker", section: .working),
            F.agent("e", section: .ended),   // real, shown agent — but not message-eligible, so never a candidate
        ])
        rig.client.outcome = .picked(agentID: "e", confidence: 0.9)
        rig.model.query = "fix it"
        rig.model.startRouting()
        await waitUntil { rig.model.routingState == nil }
        #expect(rig.model.footerNotice != nil)
        #expect(rig.source.sent.isEmpty)
    }

    @Test func aClientFailureShowsItsReasonAndSendsNothing() async {
        let rig = makeRig()
        rig.client.outcome = .failed("Jev routing timed out.")
        rig.model.query = "fix it"
        rig.model.startRouting()
        await waitUntil { rig.model.routingState == nil }
        #expect(rig.model.footerNotice?.text == "Jev routing timed out.")
        #expect(rig.source.sent.isEmpty)
    }

    // MARK: - Draft sanitization before send (same rules `MessageDraftValidator` gives the Message card)

    @Test func internalNewlinesAreFlattenedInTheTextThatIsSent() async {
        let rig = makeRig(afterRouting: .sendImmediately)
        rig.client.outcome = .picked(agentID: "w", confidence: 0.9)
        rig.model.query = "line one\nline two"
        rig.model.startRouting()
        await rig.source.waitForRequests(1)
        #expect(rig.source.sent == [.init(rowId: "w", text: "line one line two", confirmed: true)])
    }

    @Test func controlCharactersAreStrippedFromTheTextThatIsSent() async {
        let rig = makeRig(afterRouting: .sendImmediately)
        rig.client.outcome = .picked(agentID: "w", confidence: 0.9)
        rig.model.query = "hello\u{1B}world"
        rig.model.startRouting()
        await rig.source.waitForRequests(1)
        #expect(rig.source.sent == [.init(rowId: "w", text: "helloworld", confirmed: true)])
    }

    @Test func aSlashCommandIsRefusedAndKeepsTheTypedTextInTheBox() async {
        let rig = makeRig(afterRouting: .sendImmediately)
        rig.client.outcome = .picked(agentID: "w", confidence: 0.9)
        rig.model.query = "/help"   // /compact and /clear are the sole allowed exceptions (MessageDraftValidatorTests)
        rig.model.startRouting()
        await waitUntil { rig.model.routingState == nil }
        #expect(rig.model.footerNotice?.text == MessageDraftValidator.slashCommandHint)
        #expect(rig.model.query == "/help")
        #expect(rig.source.sent.isEmpty)
    }

    @Test func aTooLongDraftIsRefusedAndKeepsTheTypedTextInTheBox() async {
        let rig = makeRig(afterRouting: .sendImmediately)
        rig.client.outcome = .picked(agentID: "w", confidence: 0.9)
        let text = String(repeating: "a", count: MessageDraftValidator.maxLength + 5)
        rig.model.query = text
        rig.model.startRouting()
        await waitUntil { rig.model.routingState == nil }
        #expect(rig.model.footerNotice?.text == MessageDraftValidator.tooLongHint(over: 5))
        #expect(rig.model.query == text)
        #expect(rig.source.sent.isEmpty)
    }

    // MARK: - Sticky row note

    @Test func aConfirmedSendLeavesANoteOnTheReceivingRowUntilCleared() async {
        let rig = makeRig(afterRouting: .sendImmediately)
        rig.client.outcome = .picked(agentID: "w", confidence: 0.9)
        rig.model.query = "fix the login timeout"
        rig.model.startRouting()
        await rig.source.waitForRequests(1)
        rig.source.reply(.sent(queued: false))
        await waitUntil { !rig.model.routedNotes(for: "w").isEmpty }
        #expect(rig.model.routedNotes(for: "w").first?.text == "fix the login timeout")
        let noteID = rig.model.routedNotes(for: "w").first!.id
        rig.model.clearRoutedNote(noteID, for: "w")
        #expect(rig.model.routedNotes(for: "w").isEmpty)
    }

    @Test func aFailedSendLeavesNoNote() async {
        let rig = makeRig(afterRouting: .sendImmediately)
        rig.client.outcome = .picked(agentID: "w", confidence: 0.9)
        rig.model.query = "fix the login timeout"
        rig.model.startRouting()
        await rig.source.waitForRequests(1)
        rig.source.reply(.failed("busy"))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(rig.model.routedNotes(for: "w").isEmpty)
    }

    @Test func aNoteIsDroppedWhenItsAgentLeavesTheFeedEntirely() async {
        let rig = makeRig(afterRouting: .sendImmediately)
        rig.client.outcome = .picked(agentID: "w", confidence: 0.9)
        rig.model.query = "fix the login timeout"
        rig.model.startRouting()
        await rig.source.waitForRequests(1)
        rig.source.reply(.sent(queued: false))
        await waitUntil { !rig.model.routedNotes(for: "w").isEmpty }
        rig.model.receive(F.snapshot([]))   // the agent is gone from the feed entirely
        #expect(rig.model.routedNotes(for: "w").isEmpty)
    }

    // MARK: - Epoch race: walking away from a route must never let a stale reply hijack a later one

    /// A `JevRoutingClient` whose calls stay pending until the test resolves them, in call order —
    /// unlike `FakeJevRoutingClient` (which answers at once from a shared `outcome`), this lets a
    /// test keep a FIRST call unresolved while a SECOND one is already in flight, to reproduce the
    /// epoch race below deterministically.
    private final class GatedFakeJevRoutingClient: JevRoutingClient, @unchecked Sendable {
        private let lock = NSLock()
        private var pending: [CheckedContinuation<RouteOutcome, Never>] = []

        var callCount: Int { lock.withLock { pending.count } }

        func route(text: String, candidates: [RouteCandidate]) async -> RouteOutcome {
            await withCheckedContinuation { continuation in
                lock.withLock { pending.append(continuation) }
            }
        }

        /// Resolves the call at `index` (in call order). Callers must have first waited for
        /// `callCount > index`.
        func resolve(_ index: Int, with outcome: RouteOutcome) {
            let continuation = lock.withLock { pending[index] }
            continuation.resume(returning: outcome)
        }
    }

    /// Regression: `resetForShow()` (every ⌥Tab summon) cleared `routingState` without bumping
    /// `routingEpoch`, unlike `cancelRoutingIfActive()` (Esc). Sequence this reproduces: Shift+Return
    /// starts route 1 (epoch 0, Jev call in flight) -> panel hides/reopens mid-route (`resetForShow`
    /// clears `routingState` but epoch stayed 0) -> Shift+Return again starts route 2 (epoch still 0,
    /// second Jev call in flight) -> route 1's stale reply resolves: its guard `epoch == routingEpoch
    /// && routingState == .loading` wrongly passed (0==0, state `.loading` again from route 2), so it
    /// sent the CURRENT typed text ("second message") to the agent JEV PICKED FOR ROUTE 1 ("w1"),
    /// silently corrupting route 2 instead of leaving it to resolve on its own to "w2".
    @Test func resetForShowDropsAStaleRouteReplyThatWouldOtherwiseHijackANewerRoute() async {
        let defaults = makeScratchDefaults("routing-panel-\(UUID().uuidString)")
        let model = AgentPanelModel(
            store: FrecencyStore(defaults: defaults),
            triageStore: TriageStore(defaults: defaults),
            routedNoteStore: RoutedNoteStore(defaults: defaults),
            now: { F.now }
        )
        let source = MessageFakeSource()
        model.statusSource = source
        model.routingAPIKeyStore = FakeKeyStore(key: "sk-test")
        model.applyRouting(RoutingSettings(modelID: "~typesafe/jev-latest", afterRouting: .sendImmediately))
        let client = GatedFakeJevRoutingClient()
        model.makeRoutingClient = { _, _, _ in client }
        model.receive(F.snapshot([
            F.agent("w1", label: "worker one", section: .working),
            F.agent("w2", label: "worker two", section: .working),
        ]))

        model.query = "first message"
        model.startRouting()
        await waitUntil { client.callCount == 1 }
        #expect(model.routingState == .loading)

        model.resetForShow()   // hides then reopens the panel mid-route
        #expect(model.routingState == nil)

        model.query = "second message"
        model.startRouting()
        await waitUntil { client.callCount == 2 }
        #expect(model.routingState == .loading)

        // Route 1's reply lands now, naming the agent Jev picked for the FIRST message.
        client.resolve(0, with: .picked(agentID: "w1", confidence: 0.9))
        try? await Task.sleep(for: .milliseconds(50))
        // Fixed: the stale reply's epoch no longer matches, so nothing was sent from it — in
        // particular, "second message" was never sent to "w1".
        #expect(source.sent.isEmpty)
        #expect(model.routingState == .loading)   // route 2 untouched, still waiting on its own reply

        // Route 2 still resolves normally afterwards.
        client.resolve(1, with: .picked(agentID: "w2", confidence: 0.95))
        await source.waitForRequests(1)
        #expect(source.sent == [.init(rowId: "w2", text: "second message", confirmed: true)])
    }

    /// Regression: `useDashboard()` (switching the dashboard in Settings) reset `answer`/`permission`/
    /// `message` but left `routingState`/`routingEpoch`/`routingText` untouched. Same shape as the
    /// `resetForShow` race above: route 1 starts, the dashboard is switched mid-route (state clears,
    /// epoch unchanged), route 2 starts against the new feed (state back to `.loading`, epoch still
    /// matching) — route 1's stale reply must not be actable, or it hijacks route 2 with route 2's
    /// typed text sent to whatever agent Jev picked for route 1.
    @Test func useDashboardDropsAStaleRouteReplyThatWouldOtherwiseHijackANewerRoute() async {
        let defaults = makeScratchDefaults("routing-panel-\(UUID().uuidString)")
        let model = AgentPanelModel(
            store: FrecencyStore(defaults: defaults),
            triageStore: TriageStore(defaults: defaults),
            routedNoteStore: RoutedNoteStore(defaults: defaults),
            now: { F.now }
        )
        let source = MessageFakeSource()
        model.statusSource = source
        model.routingAPIKeyStore = FakeKeyStore(key: "sk-test")
        model.applyRouting(RoutingSettings(modelID: "~typesafe/jev-latest", afterRouting: .sendImmediately))
        let client = GatedFakeJevRoutingClient()
        model.makeRoutingClient = { _, _, _ in client }
        let agents = [
            F.agent("w1", label: "worker one", section: .working),
            F.agent("w2", label: "worker two", section: .working),
        ]
        model.receive(F.snapshot(agents))

        model.query = "first message"
        model.startRouting()
        await waitUntil { client.callCount == 1 }
        #expect(model.routingState == .loading)

        model.useDashboard(address: "10.0.0.5:9000")   // switches feeds mid-route
        #expect(model.routingState == nil)
        model.receive(F.snapshot(agents))   // the new dashboard's first update

        model.query = "second message"
        model.startRouting()
        await waitUntil { client.callCount == 2 }
        #expect(model.routingState == .loading)

        // Route 1's reply lands now, naming the agent Jev picked for the FIRST message.
        client.resolve(0, with: .picked(agentID: "w1", confidence: 0.9))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(source.sent.isEmpty)   // fixed: the stale reply's epoch no longer matches
        #expect(model.routingState == .loading)   // route 2 untouched, still waiting on its own reply

        client.resolve(1, with: .picked(agentID: "w2", confidence: 0.95))
        await source.waitForRequests(1)
        #expect(source.sent == [.init(rowId: "w2", text: "second message", confirmed: true)])
    }

    /// Regression (QA pass 2): a mouse click's `press(_:on:)` for Answer/Review/Message never
    /// checked `routingState` before opening a card, unlike `activate(agentID:)`. With a route
    /// `.confirming`, clicking a different row's Answer button used to open its card anyway — then
    /// a Return meant to submit that card hit `confirmRoutingIfPending()` first (it runs before any
    /// card check in `activateSelected()`) and sent to whatever agent Jev picked instead. Now the
    /// card-opening cases refuse outright while any route is pending, the same "nothing else should
    /// fire mid-route" rule `activate(agentID:)` already applied to clicking a row to switch to it.
    @Test func pressToOpenACardIsRefusedWhileARouteIsConfirming() async {
        let other = F.agent("other", label: "other worker", section: .needsYou, statusText: "waiting")
        let rig = makeRig(agents: [F.agent("w", label: "worker", section: .working), other])
        rig.client.outcome = .picked(agentID: "w", confidence: 0.9)
        rig.model.query = "fix the login timeout"
        rig.model.startRouting()
        await waitUntil { rig.model.routingState != .loading }
        #expect(rig.model.routingState == .confirming(agentID: "w", label: "worker", confidence: 0.9))

        _ = rig.model.press(.answer, on: "other")
        #expect(!rig.model.answer.isOpen)
        #expect(rig.model.routingState == .confirming(agentID: "w", label: "worker", confidence: 0.9))
    }
}
