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

    private static let waitingNotice = "chief-aptus's main session is waiting on you. Answer it first, or Tab to start a new session."
    private static let unreachableNotice = "chief-aptus's main session can't take messages here. Tab to start a new session."

    /// A rig whose persona `chief-aptus` has `mainAgent` as its main row, routed with typed text.
    private func mainRowRig(_ mainAgent: AgentSnapshot) -> Rig {
        let persona = PersonaFixtures.persona("chief-aptus", mainRowId: mainAgent.id, idleStart: .resume)
        let rig = makeRig(agents: [mainAgent], personas: [persona])
        rig.client.outcome = .picked(agentID: "persona:chief-aptus", confidence: 0.9)
        rig.model.query = "ship the release"
        return rig
    }

    /// The persona's main row is live but blocked on a permission box — not message-eligible.
    private static func blockedMain() -> AgentSnapshot {
        var agent = F.agent("w", label: "chief-aptus main", section: .needsYou)
        agent.blocker = .permission
        return agent
    }

    @Test func aBlockedLiveMainShowsWaitingOnYouNotStartOrResume() async {
        let rig = mainRowRig(Self.blockedMain())
        rig.model.startRouting()
        let pick = await confirmedPersonaPick(rig)
        #expect(pick?.effect == .mainWaitingOnYou)
        #expect(pick?.effect.text == "main session is waiting on you")
    }

    @Test func returnOnAWaitingMainStartsNothingKeepsTheRowAndTheTypedText() async {
        let rig = mainRowRig(Self.blockedMain())
        rig.model.startRouting()
        let pick = await confirmedPersonaPick(rig)
        rig.model.activateSelected()
        #expect(rig.model.routingState == pick.map { AgentPanelModel.RoutingState.confirmingPersona($0) })
        #expect(rig.model.footerNotice?.text == Self.waitingNotice)
        #expect(rig.model.query == "ship the release")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(rig.personas.startCalls.isEmpty)
        #expect(rig.source.sent.isEmpty)
    }

    @Test func sendImmediatelyOnAWaitingMainShowsTheConfirmRowInsteadOfStarting() async {
        let rig = mainRowRig(Self.blockedMain())
        rig.model.applyRouting(RoutingSettings(modelID: "~typesafe/jev-latest", afterRouting: .sendImmediately))
        rig.model.startRouting()
        let pick = await confirmedPersonaPick(rig)
        #expect(pick?.effect == .mainWaitingOnYou)
        #expect(rig.model.footerNotice?.text == Self.waitingNotice)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(rig.personas.startCalls.isEmpty)
    }

    @Test func tabOnAWaitingMainStillStartsANewFreshSession() async {
        let rig = mainRowRig(Self.blockedMain())
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

    @Test(arguments: [
        F.agent("w", label: "chief-aptus main", section: .working, paneId: ""),        // pane-less
        F.agent("w", label: "chief-aptus main", section: .working, hasHookData: false) // no hook data yet
    ])
    func anUnblockedMainThatCantBeMessagedIsUnreachableAndReturnStartsNothing(main: AgentSnapshot) async {
        let rig = mainRowRig(main)
        rig.model.startRouting()
        let pick = await confirmedPersonaPick(rig)
        #expect(pick?.effect == .mainUnreachable)
        #expect(pick?.effect.text == "main session can't take messages here · tab to start new")

        rig.model.activateSelected()
        #expect(rig.model.footerNotice?.text == Self.unreachableNotice)
        #expect(rig.model.routingState == pick.map { AgentPanelModel.RoutingState.confirmingPersona($0) })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(rig.personas.startCalls.isEmpty)
        #expect(rig.source.sent.isEmpty)

        #expect(rig.model.togglePersonaDeliveryOverride())
        rig.model.activateSelected()
        await waitUntil { !rig.personas.startCalls.isEmpty }
        #expect(rig.personas.startCalls == [.init(name: "chief-aptus", text: "ship the release", fresh: true)])
    }

    @Test func anEndedMainRowCountsAsNoMainSession() async {
        let rig = mainRowRig(F.agent("w", label: "chief-aptus main", section: .ended))
        rig.model.startRouting()
        let pick = await confirmedPersonaPick(rig)
        #expect(pick?.effect == .resumeLast)
    }

    // MARK: - Return re-reads the main session

    @Test func aMainThatGotBlockedSinceThePickRedrawsTheRowInsteadOfSending() async {
        let rig = mainRowRig(F.agent("w", label: "chief-aptus main", section: .working))
        rig.model.startRouting()
        let pick = await confirmedPersonaPick(rig)
        #expect(pick?.effect == .sendToMain)

        rig.model.receive(F.snapshot([Self.blockedMain()]))
        rig.model.activateSelected()
        guard case .confirmingPersona(let redrawn) = rig.model.routingState else {
            Issue.record("expected a persona confirm row"); return
        }
        #expect(redrawn.effect == .mainWaitingOnYou)
        #expect(rig.model.footerNotice == nil)   // redrawn, not yet acted on
        try? await Task.sleep(for: .milliseconds(50))
        #expect(rig.source.sent.isEmpty)
        #expect(rig.personas.startCalls.isEmpty)

        rig.model.activateSelected()   // a second Return acts on what the row now says
        #expect(rig.model.footerNotice?.text == Self.waitingNotice)
    }

    @Test func aMainThatWentAwaySinceThePickRedrawsToTheIdleStartEffect() async {
        let rig = mainRowRig(F.agent("w", label: "chief-aptus main", section: .working))
        rig.model.startRouting()
        _ = await confirmedPersonaPick(rig)

        rig.model.receive(F.snapshot([]))
        rig.model.activateSelected()
        guard case .confirmingPersona(let redrawn) = rig.model.routingState else {
            Issue.record("expected a persona confirm row"); return
        }
        #expect(redrawn.effect == .resumeLast)
        #expect(rig.personas.startCalls.isEmpty)
    }

    // MARK: - Footer hint

    @Test func theFooterNeverOffersReturnToSendOnARefusalRow() {
        #expect(PanelFooterHints.text(for: .init(routingMode: .confirmingPersonaRefusal)) == "tab start new   esc cancel")
        #expect(PanelFooterHints.text(for: .init(routingMode: .confirmingPersona)) == "↩ send   tab toggle   esc cancel")
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

    /// A rig with a persona start POST held in flight.
    private func startInFlightRig() async -> Rig {
        let persona = PersonaFixtures.persona("air-notes", idleStart: .fresh)
        let rig = makeRig(personas: [persona])
        rig.personas.gatesStart = true
        rig.client.outcome = .picked(agentID: "persona:air-notes", confidence: 0.9)
        rig.model.query = "triage the inbox"
        rig.model.startRouting()
        _ = await confirmedPersonaPick(rig)
        rig.model.activateSelected()
        await waitUntil { rig.personas.pendingStartCount == 1 }
        return rig
    }

    @Test func escWhileStartingCancelsTheRowButStillShowsTheLateOutcome() async {
        let rig = await startInFlightRig()
        #expect(rig.model.backOutOfButtons())
        #expect(rig.model.routingState == nil)
        rig.model.query = "something new"

        rig.personas.resolvePendingStart(with: .started(paneId: "w9:p1"))
        await waitUntil { rig.model.footerNotice != nil }
        #expect(rig.model.footerNotice == .created("Started air-notes"))   // the start happened: say so
        #expect(rig.model.routingState == nil)   // the late reply did not resurrect the row
        #expect(rig.model.query == "something new")   // nor wipe what was typed since
    }

    @Test func aPanelReopenWhileStartingStillShowsALateFailure() async {
        let rig = await startInFlightRig()
        rig.model.resetForShow()
        #expect(rig.model.routingState == nil)

        rig.personas.resolvePendingStart(with: .failed("herdr couldn't create a pane."))
        await waitUntil { rig.model.footerNotice != nil }
        #expect(rig.model.footerNotice?.text == "herdr couldn't create a pane.")
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
