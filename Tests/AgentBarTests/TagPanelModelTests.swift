import Foundation
import Testing
@testable import AgentBar

/// Tab-to-tag as `AgentPanelModel` drives it: tagging/re-tagging, Esc untags, Return sends through
/// the same guarded pipeline Jev-routed sends use (`MessageCardModel.sendDirect`), and the tag
/// clearing itself when the target stops being message-eligible. Against a fake dashboard source;
/// nothing here touches a real network.
@MainActor
struct TagPanelModelTests {
    typealias F = AgentListFixtures

    private struct Rig {
        let model: AgentPanelModel
        let source: MessageFakeSource
    }

    private func makeRig(_ agents: [AgentSnapshot]) -> Rig {
        let defaults = makeScratchDefaults("tag-panel-\(UUID().uuidString)")
        let model = AgentPanelModel(
            store: FrecencyStore(defaults: defaults),
            triageStore: TriageStore(defaults: defaults),
            routedNoteStore: RoutedNoteStore(defaults: defaults),
            now: { F.now }
        )
        let source = MessageFakeSource()
        model.statusSource = source
        model.receive(F.snapshot(agents))
        return Rig(model: model, source: source)
    }

    private func working(_ id: String = "w", label: String? = nil) -> AgentSnapshot {
        F.agent(id, label: label, section: .working)
    }

    // MARK: - Tagging / re-tagging

    @Test func tabTagsTheSelectedMessageEligibleRow() {
        let rig = makeRig([working()])
        rig.model.tagSelected()
        #expect(rig.model.taggedAgentID == "w")
        #expect(rig.model.taggedAgentLabel == "w")
    }

    /// The search term used to find the row (e.g. "fastt" to filter down to "fasttab-worker") is not
    /// the start of a message — the box must start empty for composing, not carry the filter over.
    @Test func tabClearsTheSearchTextUsedToFindTheAgentOnTheFirstTag() {
        let rig = makeRig([working("w", label: "fasttab-worker")])
        rig.model.query = "fastt"
        rig.model.tagSelected()
        #expect(rig.model.taggedAgentID == "w")
        #expect(rig.model.query == "")
    }

    @Test func tabDoesNothingWithoutAMessageEligibleRowSelected() {
        let rig = makeRig([F.agent("e", section: .ended)])
        rig.model.tagSelected()
        #expect(rig.model.taggedAgentID == nil)
    }

    @Test func tabDoesNothingWhileACardIsOpen() {
        let rig = makeRig([working()])
        #expect(rig.model.message.open(working()))
        rig.model.tagSelected()
        #expect(rig.model.taggedAgentID == nil)
    }

    /// Regression: the mouse path bypasses `tagSelected()`'s own "refuse while a card is open"
    /// guard entirely — `press(_:on:)` (a row's Message/Answer/Review button, or Enter on a
    /// keyboard-highlighted one) opens a card directly. Tag a row, then open a card on ANY row
    /// (same or different) without going through Tab again: the card taking over the keyboard must
    /// drop the now-invisible tag, or a first Esc silently untags instead of closing the card the
    /// user is actually looking at (and the footer would claim Return sends the tagged message).
    @Test func openingAnyCardWhileTaggedClearsTheTag() {
        let rig = makeRig([working("w1", label: "worker one"), working("w2", label: "worker two")])
        rig.model.tagSelected()   // tags "w1"
        #expect(rig.model.taggedAgentID == "w1")
        rig.model.press(.message, on: "w2")   // e.g. clicking "w2"'s Message pill
        #expect(rig.model.message.isOpen)
        #expect(rig.model.taggedAgentID == nil)
        // Esc now closes the card that's actually open, in one press — not the (already gone) tag.
        #expect(rig.model.backOutOfButtons())
        #expect(!rig.model.message.isOpen)
    }

    /// Regression (QA): Space opens a peek before any tag exists (`togglePeek()` only refuses while
    /// already tagged, not the reverse), then Tab tags that same row. Nothing used to close the
    /// peek, so it kept rendering at full body height while `AgentPanelMetrics.height(isComposing:)`
    /// had already collapsed the window to the composing floor — the peek's content got clipped
    /// against a window sized for "nothing shown". `tagSelected()` must close the peek, the same way
    /// every card-opening path already drops the tag.
    @Test func tabWhilePeekingClosesThePeekAndTagsInstead() {
        let rig = makeRig([working()])
        #expect(rig.model.togglePeek())   // opens the peek (not yet tagged, box empty)
        #expect(rig.model.peek != nil)
        rig.model.tagSelected()
        #expect(rig.model.taggedAgentID == "w")
        #expect(rig.model.peek == nil)
    }

    @Test func retaggingSwapsTheTargetWithoutTouchingTypedText() {
        let rig = makeRig([working("w1", label: "worker one"), working("w2", label: "worker two")])
        rig.model.tagSelected()   // tags "w1", the first selectable row
        #expect(rig.model.taggedAgentID == "w1")
        rig.model.query = "worker"   // typing continues to filter the list too, as it always does
        rig.model.moveSelection(by: 1)   // arrow to "w2" among the rows still matching
        rig.model.tagSelected()
        #expect(rig.model.taggedAgentID == "w2")
        #expect(rig.model.query == "worker")   // re-tagging never touches what's already typed
    }

    // MARK: - Esc untags

    @Test func escUntagsAndKeepsTheTypedText() {
        let rig = makeRig([working()])
        rig.model.tagSelected()
        rig.model.query = "hello"
        #expect(rig.model.backOutOfButtons())
        #expect(rig.model.taggedAgentID == nil)
        #expect(rig.model.query == "hello")
    }

    // MARK: - Return while tagged sends, through the same guarded pipeline routing uses

    @Test func returnWhileTaggedSendsAndClearsTheBoxAndTheTag() async {
        let rig = makeRig([working()])
        rig.model.tagSelected()
        rig.model.query = "fix the login timeout"
        rig.model.activateSelected()
        #expect(rig.model.taggedAgentID == nil)
        #expect(rig.model.query == "")
        await rig.source.waitForRequests(1)
        #expect(rig.source.sent == [.init(rowId: "w", text: "fix the login timeout", confirmed: true)])
    }

    @Test func returnWhileTaggedDoesNotFallThroughToActivatingTheSelectedAgent() async {
        let rig = makeRig([working()])
        var activated = 0
        rig.model.onActivate = { _ in activated += 1 }
        rig.model.tagSelected()
        rig.model.query = "hello"
        rig.model.activateSelected()
        await rig.source.waitForRequests(1)
        #expect(activated == 0)
    }

    @Test func returnWithAnEmptyBoxWhileTaggedSendsNothingAndKeepsTheTag() {
        let rig = makeRig([working()])
        rig.model.tagSelected()
        rig.model.activateSelected()
        #expect(rig.model.taggedAgentID == "w")
        #expect(rig.model.footerNotice?.text == "Nothing to send.")
        #expect(rig.source.sent.isEmpty)
    }

    @Test func aSlashCommandWhileTaggedIsRefusedAndKeepsTheTypedTextAndTheTag() {
        let rig = makeRig([working()])
        rig.model.tagSelected()
        rig.model.query = "/help"   // /compact and /clear are the sole allowed exceptions (MessageDraftValidatorTests)
        rig.model.activateSelected()
        #expect(rig.model.taggedAgentID == "w")
        #expect(rig.model.query == "/help")
        #expect(rig.model.footerNotice?.text == MessageDraftValidator.slashCommandHint)
        #expect(rig.source.sent.isEmpty)
    }

    @Test func internalNewlinesAreFlattenedInTheTextThatIsSent() async {
        let rig = makeRig([working()])
        rig.model.tagSelected()
        rig.model.query = "line one\nline two"
        rig.model.activateSelected()
        await rig.source.waitForRequests(1)
        #expect(rig.source.sent == [.init(rowId: "w", text: "line one line two", confirmed: true)])
    }

    /// Regression: `sendDirect` (the send this flow shares with Jev routing) has no UI to show a
    /// confirm step, so a busy agent must just queue on the first press rather than dead-end.
    @Test func returnWhileTaggedQueuesInsteadOfFailingWhenTheAgentIsBusy() async {
        let rig = makeRig([working()])
        rig.model.tagSelected()
        rig.model.query = "keep going"
        rig.model.activateSelected()
        await rig.source.waitForRequests(1)
        #expect(rig.source.sent == [.init(rowId: "w", text: "keep going", confirmed: true)])
    }

    // MARK: - Tagging and Jev routing are mutually exclusive

    @Test func tabWhileARouteIsConfirmingCancelsTheRouteAndTagsInstead() async {
        let rig = makeRig([working("w1", label: "worker one"), working("w2", label: "worker two")])
        let keyStore = FakeRoutingAPIKeyStore()
        try? keyStore.set("sk-test")
        rig.model.routingAPIKeyStore = keyStore
        let client = FakeJevRoutingClient()
        client.outcome = .picked(agentID: "w1", confidence: 0.9)
        rig.model.makeRoutingClient = { _, _ in client }
        // "worker" (not a real message — chosen so both rows still match it) keeps "w2" selectable
        // by arrow key below; a real message rarely name-matches every row, which is a separate,
        // pre-existing limitation of arrow-selecting while composing (shared with Jev routing).
        rig.model.query = "worker"
        rig.model.startRouting()
        await waitUntil { rig.model.routingState != .loading }
        #expect(rig.model.routingState == .confirming(agentID: "w1", label: "worker one", confidence: 0.9))

        rig.model.moveSelection(by: 1)   // arrow to "w2"
        rig.model.tagSelected()
        #expect(rig.model.routingState == nil)   // tagging cancels the pending route
        #expect(rig.model.taggedAgentID == "w2")
        #expect(rig.source.sent.isEmpty)   // the cancelled route's own confirm never fired
        // Unlike tagging straight from a plain search, the box was already a message-in-progress
        // (that's what Jev was about to route) — cancelling the route for an explicit tag instead
        // must not throw that typed message away.
        #expect(rig.model.query == "worker")
    }

    @Test func shiftReturnRoutingIsRefusedWhileTagged() {
        let rig = makeRig([working()])
        rig.model.tagSelected()
        rig.model.query = "hello"
        rig.model.startRouting()
        #expect(rig.model.routingState == nil)   // guard returned early — never asked Jev
        #expect(rig.model.taggedAgentID == "w")   // the tag is untouched
    }

    // MARK: - The tag clears itself when the target stops being eligible

    @Test func theTagClearsWithANoticeWhenTheTargetEndsMidCompose() {
        let rig = makeRig([working()])
        rig.model.tagSelected()
        rig.model.query = "hello"
        rig.model.receive(F.snapshot([F.agent("w", label: "w", section: .ended)]))
        #expect(rig.model.taggedAgentID == nil)
        #expect(rig.model.footerNotice?.text.contains("can no longer take a message") == true)
        #expect(rig.model.query == "hello")   // typed text survives — only the target is dropped
    }

    /// Regression: a transient dashboard outage (`StatusFeedHealth.down`) reports an empty agent
    /// list too — contractually indistinguishable, by agent count alone, from the tagged agent
    /// having genuinely left. `pruneRoutedNotes`/`blockerProbe.observe` already special-case this
    /// ("a dead feed shows no agents; that must not read as 'they all went away'"); the tag must get
    /// the same treatment, or a flaky connection silently drops what the user is mid-typing to.
    @Test func theTagSurvivesATransientFeedOutageAndIsNotClearedByIt() {
        let rig = makeRig([working()])
        rig.model.tagSelected()
        rig.model.query = "hello"
        rig.model.receive(F.snapshot([], health: .down(reason: "dashboard unreachable")))
        #expect(rig.model.taggedAgentID == "w")
        #expect(rig.model.query == "hello")
        // The feed recovers: the tag is still exactly what it was, ready to send.
        rig.model.receive(F.snapshot([working()]))
        #expect(rig.model.taggedAgentID == "w")
    }

    @Test func theTagClearsWithANoticeWhenTheTargetLeavesTheFeedEntirely() {
        let rig = makeRig([working()])
        rig.model.tagSelected()
        rig.model.receive(F.snapshot([]))
        #expect(rig.model.taggedAgentID == nil)
        #expect(rig.model.footerNotice?.text.contains("can no longer take a message") == true)
    }

    // MARK: - Full resets

    @Test func resetForShowClearsTheTag() {
        let rig = makeRig([working()])
        rig.model.tagSelected()
        rig.model.resetForShow()
        #expect(rig.model.taggedAgentID == nil)
    }

    @Test func useDashboardClearsTheTag() {
        let rig = makeRig([working()])
        rig.model.tagSelected()
        rig.model.useDashboard(address: "10.0.0.5:9000")
        #expect(rig.model.taggedAgentID == nil)
    }
}
