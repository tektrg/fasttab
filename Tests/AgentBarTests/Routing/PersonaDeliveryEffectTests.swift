import Foundation
import Testing
@testable import AgentBar

/// `PersonaDeliveryEffect.derive` — the three-way choice a persona confirm row shows and
/// `AgentPanelModel.deliverPersonaPick(_:)` acts on. Pure, so no rig needed.
struct PersonaDeliveryEffectTests {
    @Test func aLiveMainSessionAlwaysWinsRegardlessOfIdleStart() {
        #expect(PersonaDeliveryEffect.derive(hasLiveMain: true, idleStart: .fresh, forcedStartNew: false) == .sendToMain)
        #expect(PersonaDeliveryEffect.derive(hasLiveMain: true, idleStart: .resume, forcedStartNew: false) == .sendToMain)
    }

    @Test func noLiveMainFallsBackToThePersonasOwnIdleStartDefault() {
        #expect(PersonaDeliveryEffect.derive(hasLiveMain: false, idleStart: .resume, forcedStartNew: false) == .resumeLast)
        #expect(PersonaDeliveryEffect.derive(hasLiveMain: false, idleStart: .fresh, forcedStartNew: false) == .startNew)
    }

    @Test func forcedStartNewOverridesEverythingIncludingALiveMain() {
        #expect(PersonaDeliveryEffect.derive(hasLiveMain: true, idleStart: .resume, forcedStartNew: true) == .startNew)
        #expect(PersonaDeliveryEffect.derive(hasLiveMain: false, idleStart: .resume, forcedStartNew: true) == .startNew)
    }

    @Test func textMatchesTheConfirmRowWordingForAllThreeCases() {
        #expect(PersonaDeliveryEffect.sendToMain.text == "send to main session")
        #expect(PersonaDeliveryEffect.resumeLast.text == "resume last conversation")
        #expect(PersonaDeliveryEffect.startNew.text == "start new session")
    }
}
