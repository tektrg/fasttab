import Foundation
import Testing
@testable import AgentBar

/// `PersonaDeliveryEffect.derive` — the choice a persona confirm row shows and
/// `AgentPanelModel.deliverPersonaPick(_:)` acts on. Pure, so no rig needed.
struct PersonaDeliveryEffectTests {
    private let ready = PersonaMainSession.ready(agentID: "w")
    private let waiting = PersonaMainSession.waitingOnYou(agentID: "w")

    @Test func aLiveMainSessionAlwaysWinsRegardlessOfIdleStart() {
        #expect(PersonaDeliveryEffect.derive(mainSession: ready, idleStart: .fresh, forcedStartNew: false) == .sendToMain)
        #expect(PersonaDeliveryEffect.derive(mainSession: ready, idleStart: .resume, forcedStartNew: false) == .sendToMain)
    }

    @Test func aLiveMainThatCantTakeAMessageWaitsRatherThanStartingAnother() {
        #expect(PersonaDeliveryEffect.derive(mainSession: waiting, idleStart: .fresh, forcedStartNew: false) == .mainWaitingOnYou)
        #expect(PersonaDeliveryEffect.derive(mainSession: waiting, idleStart: .resume, forcedStartNew: false) == .mainWaitingOnYou)
    }

    @Test func noLiveMainFallsBackToThePersonasOwnIdleStartDefault() {
        #expect(PersonaDeliveryEffect.derive(mainSession: .absent, idleStart: .resume, forcedStartNew: false) == .resumeLast)
        #expect(PersonaDeliveryEffect.derive(mainSession: .absent, idleStart: .fresh, forcedStartNew: false) == .startNew)
    }

    @Test func forcedStartNewOverridesEverythingIncludingALiveMain() {
        #expect(PersonaDeliveryEffect.derive(mainSession: ready, idleStart: .resume, forcedStartNew: true) == .startNew)
        #expect(PersonaDeliveryEffect.derive(mainSession: waiting, idleStart: .resume, forcedStartNew: true) == .startNew)
        #expect(PersonaDeliveryEffect.derive(mainSession: .absent, idleStart: .resume, forcedStartNew: true) == .startNew)
    }

    @Test func textMatchesTheConfirmRowWordingForEveryCase() {
        #expect(PersonaDeliveryEffect.sendToMain.text == "send to main session")
        #expect(PersonaDeliveryEffect.mainWaitingOnYou.text == "main session is waiting on you")
        #expect(PersonaDeliveryEffect.resumeLast.text == "resume last conversation")
        #expect(PersonaDeliveryEffect.startNew.text == "start new session")
    }
}
