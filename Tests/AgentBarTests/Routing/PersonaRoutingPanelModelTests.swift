import Foundation
import Testing
@testable import AgentBar

/// A persona pick on the Shift+Return confirm row (`AgentPanelModel.RoutingState.confirmingPersona`):
/// the effect text it shows, Tab's delivery-mode toggle, and where Return actually sends — the
/// existing `sendDirect` pipeline for a live main session, `POST /api/persona/start` otherwise.
/// Against fake Jev, dashboard, and persona sources; nothing here touches a real network.
@MainActor
struct PersonaRoutingPanelModelTests {
    typealias F = AgentListFixtures

    private struct Rig {
        let model: AgentPanelModel
        let client: FakeJevRoutingClient
        let source: MessageFakeSource
        let personas: FakePersonaDirectorySource
    }

    private func makeRig(agents: [AgentSnapshot] = [], personas: [Persona] = []) -> Rig {
        let defaults = makeScratchDefaults("persona-routing-\(UUID().uuidString)")
        let model = AgentPanelModel(
            store: FrecencyStore(defaults: defaults),
            triageStore: TriageStore(defaults: defaults),
            routedNoteStore: RoutedNoteStore(defaults: defaults),
            now: { F.now }
        )
        let source = MessageFakeSource()
        model.statusSource = source
        let personaSource = FakePersonaDirectorySource()
        personaSource.personas = personas
        model.personaSource = personaSource
        let keyStore = FakeRoutingAPIKeyStore()
        try? keyStore.set("sk-test")
        model.routingAPIKeyStore = keyStore
        model.applyRouting(RoutingSettings(modelID: "~typesafe/jev-latest", afterRouting: .confirmFirst))
        let client = FakeJevRoutingClient()
        model.makeRoutingClient = { _, _, _ in client }
        model.receive(F.snapshot(agents))
        return Rig(model: model, client: client, source: source, personas: personaSource)
    }

    /// Drives a route to its persona confirm row and returns the pick, failing the test if routing
    /// resolved to anything else.
    private func confirmedPersonaPick(_ rig: Rig) async -> PersonaPick? {
        await waitUntil { rig.model.routingState != .loading }
        guard case .confirmingPersona(let pick) = rig.model.routingState else {
            Issue.record("expected a persona confirm row, got \(String(describing: rig.model.routingState))")
            return nil
        }
        return pick
    }

    // MARK: - Confirm-row effect

    @Test func aLiveMainSessionShowsSendToMainAndNeverAutoSends() async {
        let agent = F.agent("w", label: "chief-aptus main", section: .working)
        let persona = PersonaFixtures.persona("chief-aptus", mainRowId: "w")
        let rig = makeRig(agents: [agent], personas: [persona])
        rig.client.outcome = .picked(agentID: "persona:chief-aptus", confidence: 0.9)
        rig.model.query = "ship the release"
        rig.model.startRouting()
        let pick = await confirmedPersonaPick(rig)
        #expect(pick?.effect == .sendToMain)
        #expect(rig.source.sent.isEmpty)
        #expect(rig.personas.startCalls.isEmpty)
    }

    @Test func noLiveMainWithIdleStartResumeShowsResumeLast() async {
        let persona = PersonaFixtures.persona("air-notes", idleStart: .resume)
        let rig = makeRig(personas: [persona])
        rig.client.outcome = .picked(agentID: "persona:air-notes", confidence: 0.9)
        rig.model.query = "triage the inbox"
        rig.model.startRouting()
        let pick = await confirmedPersonaPick(rig)
        #expect(pick?.effect == .resumeLast)
    }

    @Test func noLiveMainWithIdleStartFreshOrMissingShowsStartNew() async {
        let persona = PersonaFixtures.persona("air-notes", idleStart: nil)
        let rig = makeRig(personas: [persona])
        rig.client.outcome = .picked(agentID: "persona:air-notes", confidence: 0.9)
        rig.model.query = "triage the inbox"
        rig.model.startRouting()
        let pick = await confirmedPersonaPick(rig)
        #expect(pick?.effect == .startNew)
    }

    // MARK: - Tab toggles the delivery mode

    @Test func tabFlipsTheEffectToStartNewAndBackAgain() async {
        let persona = PersonaFixtures.persona("air-notes", idleStart: .resume)
        let rig = makeRig(personas: [persona])
        rig.client.outcome = .picked(agentID: "persona:air-notes", confidence: 0.9)
        rig.model.query = "triage the inbox"
        rig.model.startRouting()
        _ = await confirmedPersonaPick(rig)

        #expect(rig.model.togglePersonaDeliveryOverride())
        guard case .confirmingPersona(let toggled) = rig.model.routingState else {
            Issue.record("expected a persona confirm row"); return
        }
        #expect(toggled.effect == .startNew)

        #expect(rig.model.togglePersonaDeliveryOverride())
        guard case .confirmingPersona(let toggledBack) = rig.model.routingState else {
            Issue.record("expected a persona confirm row"); return
        }
        #expect(toggledBack.effect == .resumeLast)
    }

    @Test func tabDoesNothingWhenNoPersonaConfirmRowIsShowing() {
        let rig = makeRig()
        #expect(!rig.model.togglePersonaDeliveryOverride())
    }

    // MARK: - Delivery: live main -> the existing sendDirect pipeline, unchanged

    @Test func returnOnALiveMainSendsThroughTheExistingMessagePipeline() async {
        let agent = F.agent("w", label: "chief-aptus main", section: .working)
        let persona = PersonaFixtures.persona("chief-aptus", mainRowId: "w")
        let rig = makeRig(agents: [agent], personas: [persona])
        rig.client.outcome = .picked(agentID: "persona:chief-aptus", confidence: 0.9)
        rig.model.query = "ship the release"
        rig.model.startRouting()
        _ = await confirmedPersonaPick(rig)
        rig.model.activateSelected()
        await rig.source.waitForRequests(1)
        #expect(rig.source.sent == [.init(rowId: "w", text: "ship the release", confirmed: true)])
        #expect(rig.model.routingState == nil)
        #expect(rig.model.query == "")
        #expect(rig.personas.startCalls.isEmpty)
    }

    // MARK: - Live main that can't take a message: never a duplicate session

    /// The persona's main row is live but blocked on a permission box — not message-eligible.
    private func waitingMainRig() -> Rig {
        var agent = F.agent("w", label: "chief-aptus main", section: .needsYou)
        agent.blocker = .permission
        let persona = PersonaFixtures.persona("chief-aptus", mainRowId: "w", idleStart: .resume)
        let rig = makeRig(agents: [agent], personas: [persona])
        rig.client.outcome = .picked(agentID: "persona:chief-aptus", confidence: 0.9)
        rig.model.query = "ship the release"
        return rig
    }

    @Test func aBlockedLiveMainShowsWaitingOnYouNotStartOrResume() async {
        let rig = waitingMainRig()
        rig.model.startRouting()
        let pick = await confirmedPersonaPick(rig)
        #expect(pick?.effect == .mainWaitingOnYou)
        #expect(pick?.effect.text == "main session is waiting on you")
    }

    @Test func returnOnAWaitingMainStartsNothingAndKeepsTheTypedText() async {
        let rig = waitingMainRig()
        rig.model.startRouting()
        _ = await confirmedPersonaPick(rig)
        rig.model.activateSelected()
        #expect(rig.model.routingState == nil)
        #expect(rig.model.footerNotice?.text == "chief-aptus's main session is waiting on you. Answer it, then send again.")
        #expect(rig.model.query == "ship the release")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(rig.personas.startCalls.isEmpty)
        #expect(rig.source.sent.isEmpty)
    }

    @Test func sendImmediatelyOnAWaitingMainStartsNothingEither() async {
        let rig = waitingMainRig()
        rig.model.applyRouting(RoutingSettings(modelID: "~typesafe/jev-latest", afterRouting: .sendImmediately))
        rig.model.startRouting()
        await waitUntil { rig.model.routingState == nil }
        #expect(rig.model.footerNotice?.text == "chief-aptus's main session is waiting on you. Answer it, then send again.")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(rig.personas.startCalls.isEmpty)
    }

    @Test func tabOnAWaitingMainStillStartsANewFreshSession() async {
        let rig = waitingMainRig()
        rig.model.startRouting()
        _ = await confirmedPersonaPick(rig)
        #expect(rig.model.togglePersonaDeliveryOverride())
        guard case .confirmingPersona(let toggled) = rig.model.routingState else {
            Issue.record("expected a persona confirm row"); return
        }
        #expect(toggled.effect == .startNew)
        rig.model.activateSelected()
        await waitUntil { !rig.personas.startCalls.isEmpty }
        #expect(rig.personas.startCalls == [.init(name: "chief-aptus", text: "ship the release", fresh: true)])
    }

    @Test func anEndedMainRowCountsAsNoMainSession() async {
        let agent = F.agent("w", label: "chief-aptus main", section: .ended)
        let persona = PersonaFixtures.persona("chief-aptus", mainRowId: "w", idleStart: .resume)
        let rig = makeRig(agents: [agent], personas: [persona])
        rig.client.outcome = .picked(agentID: "persona:chief-aptus", confidence: 0.9)
        rig.model.query = "ship the release"
        rig.model.startRouting()
        let pick = await confirmedPersonaPick(rig)
        #expect(pick?.effect == .resumeLast)
    }

    // MARK: - Delivery: no live main -> POST /api/persona/start

    @Test func returnWithNoLiveMainStartsThroughTheDashboardWithFreshFalse() async {
        let persona = PersonaFixtures.persona("air-notes", idleStart: .resume)
        let rig = makeRig(personas: [persona])
        rig.client.outcome = .picked(agentID: "persona:air-notes", confidence: 0.9)
        rig.model.query = "triage the inbox"
        rig.model.startRouting()
        _ = await confirmedPersonaPick(rig)
        rig.model.activateSelected()
        await waitUntil { !rig.personas.startCalls.isEmpty }
        #expect(rig.personas.startCalls == [.init(name: "air-notes", text: "triage the inbox", fresh: false)])
    }

    @Test func tabbedToStartNewSendsFreshTrue() async {
        let persona = PersonaFixtures.persona("air-notes", idleStart: .resume)
        let rig = makeRig(personas: [persona])
        rig.client.outcome = .picked(agentID: "persona:air-notes", confidence: 0.9)
        rig.model.query = "triage the inbox"
        rig.model.startRouting()
        _ = await confirmedPersonaPick(rig)
        #expect(rig.model.togglePersonaDeliveryOverride())
        rig.model.activateSelected()
        await waitUntil { !rig.personas.startCalls.isEmpty }
        #expect(rig.personas.startCalls == [.init(name: "air-notes", text: "triage the inbox", fresh: true)])
    }

    @Test func startingShowsUntilTheReplyLandsThenAGreenStartedNotice() async {
        let persona = PersonaFixtures.persona("air-notes", idleStart: .fresh)
        let rig = makeRig(personas: [persona])
        rig.personas.gatesStart = true
        rig.client.outcome = .picked(agentID: "persona:air-notes", confidence: 0.9)
        rig.model.query = "triage the inbox"
        rig.model.startRouting()
        _ = await confirmedPersonaPick(rig)
        rig.model.activateSelected()
        await waitUntil { rig.personas.pendingStartCount == 1 }
        #expect(rig.model.routingState == .startingPersona(name: "air-notes"))

        rig.personas.resolvePendingStart(with: .started(paneId: "w9:p1"))
        await waitUntil { rig.model.routingState == nil }
        #expect(rig.model.footerNotice == .created("Started air-notes"))
        #expect(rig.model.query == "")
    }

    @Test func aResumedOutcomeShowsTheResumedNotice() async {
        let persona = PersonaFixtures.persona("air-notes", idleStart: .resume)
        let rig = makeRig(personas: [persona])
        rig.personas.startOutcome = .resumed(paneId: "w9:p1")
        rig.client.outcome = .picked(agentID: "persona:air-notes", confidence: 0.9)
        rig.model.query = "triage the inbox"
        rig.model.startRouting()
        _ = await confirmedPersonaPick(rig)
        rig.model.activateSelected()
        await waitUntil { rig.model.routingState == nil }
        #expect(rig.model.footerNotice == .created("Resumed air-notes"))
    }

    // MARK: - Start failures: shown, never auto-retried

    @Test func aFailedStartShowsTheErrorAndKeepsTheTypedTextAndNeverAutoRetries() async {
        let persona = PersonaFixtures.persona("air-notes", idleStart: .fresh)
        let rig = makeRig(personas: [persona])
        rig.personas.startOutcome = .failed("herdr couldn't create a pane.")
        rig.client.outcome = .picked(agentID: "persona:air-notes", confidence: 0.9)
        rig.model.query = "triage the inbox"
        rig.model.startRouting()
        _ = await confirmedPersonaPick(rig)
        rig.model.activateSelected()
        await waitUntil { rig.model.routingState == nil }
        #expect(rig.model.footerNotice?.text == "herdr couldn't create a pane.")
        #expect(rig.model.query == "triage the inbox")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(rig.personas.startCalls.count == 1)   // no automatic retry of a persona start
    }

    // MARK: - Esc while starting cancels and drops the late reply

    @Test func escWhileStartingCancelsAndDropsTheLateReply() async {
        let persona = PersonaFixtures.persona("air-notes", idleStart: .fresh)
        let rig = makeRig(personas: [persona])
        rig.personas.gatesStart = true
        rig.client.outcome = .picked(agentID: "persona:air-notes", confidence: 0.9)
        rig.model.query = "triage the inbox"
        rig.model.startRouting()
        _ = await confirmedPersonaPick(rig)
        rig.model.activateSelected()
        await waitUntil { rig.personas.pendingStartCount == 1 }

        #expect(rig.model.backOutOfButtons())
        #expect(rig.model.routingState == nil)

        rig.personas.resolvePendingStart(with: .started(paneId: "w9:p1"))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(rig.model.routingState == nil)   // the late reply did not resurrect it
        #expect(rig.model.footerNotice == nil)
    }

    // MARK: - No dashboard to start on

    @Test func withNoPersonaSourceAtAllTheStartIsRefusedWithANotice() async {
        let persona = PersonaFixtures.persona("air-notes", idleStart: .fresh)
        let rig = makeRig(personas: [persona])
        rig.client.outcome = .picked(agentID: "persona:air-notes", confidence: 0.9)
        rig.model.query = "triage the inbox"
        rig.model.startRouting()
        _ = await confirmedPersonaPick(rig)
        rig.model.personaSource = nil   // the dashboard connection dropped between fetch and Return
        rig.model.activateSelected()
        #expect(rig.model.routingState == nil)
        #expect(rig.model.footerNotice?.text == "No status dashboard to start air-notes on.")
    }
}
