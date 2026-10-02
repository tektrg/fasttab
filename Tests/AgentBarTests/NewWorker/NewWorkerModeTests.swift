import Foundation
import Testing
@testable import AgentBar

/// New worker mode: `/new` (or "+") → pick a persona folder → type the first task → Return starts a
/// FRESH session on the chosen machine through the Jev persona start path. Fakes only.
@MainActor
struct NewWorkerModeTests {
    typealias F = AgentListFixtures

    private static let pro = PersonaMachine(id: "local", label: "Pro")
    private static let air = PersonaMachine(id: "air-m1", label: "Air")
    private static let hostile = "$(echo INJECTED)"

    private static func persona(_ name: String, offline: Bool = false, runsOn: String? = "local",
                                machines: [PersonaMachine]? = [pro, air]) -> Persona {
        var persona = PersonaFixtures.persona(name, offline: offline, mainRowId: "row-live", idleStart: .resume)
        persona.runsOn = runsOn
        persona.machines = machines
        return persona
    }

    private static let folders = [
        persona("chief-aptus"),
        persona("agentbar", runsOn: "air-m1"),
        persona("asleep", offline: true),
        persona("bi", runsOn: nil, machines: nil),
    ]

    private struct Rig {
        let model: AgentPanelModel
        let personas: FakePersonaDirectorySource
    }

    private func rig(personas: [Persona] = folders) -> Rig {
        let defaults = makeScratchDefaults("new-worker-\(UUID().uuidString)")
        let model = AgentPanelModel(
            store: FrecencyStore(defaults: defaults),
            triageStore: TriageStore(defaults: defaults),
            routedNoteStore: RoutedNoteStore(defaults: defaults),
            now: { F.now }
        )
        model.statusSource = MessageFakeSource()
        let source = FakePersonaDirectorySource()
        source.personas = personas
        model.personaSource = source
        model.receive(F.snapshot([]))
        return Rig(model: model, personas: source)
    }

    private func enteredRig(personas: [Persona] = folders) async -> Rig {
        let rig = rig(personas: personas)
        rig.model.query = "/new"
        rig.model.activateSelected()
        await waitUntil { rig.model.newWorker?.folders != .loading }
        return rig
    }

    private func composingRig(folder: String) async -> Rig {
        let rig = await enteredRig()
        rig.model.query = folder
        rig.model.activateSelected()
        return rig
    }

    // MARK: - Entry

    @Test func entryCommandIsSlashNewOnly() {
        #expect(NewWorkerMode.isEntryCommand("/new"))
        #expect(NewWorkerMode.isEntryCommand("  /NEW "))
        #expect(!NewWorkerMode.isEntryCommand("/newer"))
        #expect(!NewWorkerMode.isEntryCommand("new"))
    }

    @Test func slashNewReturnEntersStepOneWithOnlineFolders() async {
        let rig = await enteredRig()
        #expect(rig.model.query == "")
        #expect(rig.model.newWorker?.isComposing == false)
        #expect(rig.model.newWorkerFolders.map(\.name) == ["chief-aptus", "agentbar", "bi"])
        #expect(rig.model.newWorkerSelectedFolderName == "chief-aptus")
    }

    @Test func plusButtonPathEntersTooAndNoDashboardShowsFailed() {
        let rig = rig()
        rig.model.personaSource = nil
        rig.model.enterNewWorkerMode()
        #expect(rig.model.newWorker?.folders == .failed)
        #expect(rig.model.newWorkerFolders.isEmpty)
    }

    @Test func plainReturnWithoutSlashNewDoesNotEnter() {
        let rig = rig()
        rig.model.query = "agentbar"
        rig.model.activateSelected()
        #expect(rig.model.newWorker == nil)
    }

    // MARK: - Step 1

    @Test func typingFiltersByNameAndArrowsMoveClamped() async {
        let rig = await enteredRig()
        rig.model.moveSelectionOrAnswerHighlight(by: 1)
        #expect(rig.model.newWorkerSelectedFolderName == "agentbar")
        rig.model.moveSelectionOrAnswerHighlight(by: 5)
        #expect(rig.model.newWorkerSelectedFolderName == "bi")
        rig.model.query = "A"
        #expect(rig.model.newWorkerFolders.map(\.name) == ["chief-aptus", "agentbar"])
        #expect(rig.model.newWorkerSelectedFolderName == "chief-aptus")   // filter change → first match
        rig.model.moveSelectionOrAnswerHighlight(by: -1)
        #expect(rig.model.newWorkerSelectedFolderName == "chief-aptus")
    }

    @Test func spaceAndTabStayInertOverTheFolderList() async {
        let rig = await enteredRig()
        #expect(!rig.model.togglePeek())
        rig.model.tagSelected()
        #expect(rig.model.taggedAgentID == nil)
        #expect(!rig.model.moveButtonHighlight(by: 1))
    }

    @Test func returnPicksTheFolderAsAForcedFreshStartOnRunsOn() async {
        let rig = await composingRig(folder: "agentbar")
        let pick = rig.model.newWorkerPick
        #expect(pick?.persona.name == "agentbar")
        #expect(pick?.forcedStartNew == true)
        #expect(pick?.effect == .startNew)
        #expect(pick?.machineID == "air-m1")
        #expect(rig.model.query == "")
    }

    @Test func returnWithNoMatchingFolderStaysOnStepOne() async {
        let rig = await enteredRig()
        rig.model.query = "zzz"
        rig.model.activateSelected()
        #expect(rig.model.newWorker?.isComposing == false)
    }

    // MARK: - Back

    @Test func escGoesBackToStepOneThenLeavesTheMode() async {
        let rig = await composingRig(folder: "agentbar")
        rig.model.query = "half-typed task"
        #expect(rig.model.backOutOfButtons())
        #expect(rig.model.newWorker?.isComposing == false)
        #expect(rig.model.query == "agentbar")
        #expect(rig.model.newWorkerSelectedFolderName == "agentbar")
        #expect(rig.model.backOutOfButtons())
        #expect(rig.model.newWorker == nil)
        #expect(rig.model.query == "")
    }

    @Test func showingThePanelAgainLeavesTheMode() async {
        let rig = await enteredRig()
        rig.model.resetForShow()
        #expect(rig.model.newWorker == nil)
    }

    // MARK: - Start

    @Test func returnStartsFreshOnTheChosenMachine() async {
        let rig = await composingRig(folder: "chief-aptus")
        #expect(rig.model.movePersonaMachine(by: 1))
        #expect(rig.model.newWorkerPick?.machineID == "air-m1")
        rig.personas.startOutcome = .started(paneId: "w1:p1")
        rig.model.query = Self.hostile
        rig.model.activateSelected()
        await waitUntil { rig.model.footerNotice != nil }
        #expect(rig.personas.startCalls == [.init(name: "chief-aptus", text: Self.hostile, fresh: true, machine: "air-m1")])
        #expect(rig.model.newWorker == nil)
        #expect(rig.model.query == "")
        #expect(rig.model.routingState == nil)
        #expect(rig.model.footerNotice?.text == "Started chief-aptus")
    }

    @Test func noChipsMeansArrowsAreNotClaimedAndNoMachineIsSent() async {
        let rig = await composingRig(folder: "bi")
        #expect(!rig.model.movePersonaMachine(by: 1))
        rig.personas.startOutcome = .started(paneId: "w1:p1")
        rig.model.query = "do the thing"
        rig.model.activateSelected()
        await waitUntil { !rig.personas.startCalls.isEmpty }
        #expect(rig.personas.startCalls == [.init(name: "bi", text: "do the thing", fresh: true, machine: nil)])
    }

    @Test func emptyOrSlashFirstTaskIsBlockedAndStaysOnStepTwo() async {
        let rig = await composingRig(folder: "agentbar")
        rig.model.activateSelected()
        #expect(rig.model.footerNotice?.text == "Nothing to send.")
        #expect(rig.model.newWorker?.isComposing == true)
        rig.model.query = "/compact"
        rig.model.activateSelected()
        #expect(rig.model.footerNotice?.text == MessageDraftValidator.slashCommandHint)
        #expect(rig.model.newWorker?.isComposing == true)
        #expect(rig.model.query == "/compact")
        #expect(rig.personas.startCalls.isEmpty)
    }

    @Test func unreachableReusesTheJevRetryRow() async {
        let rig = await composingRig(folder: "agentbar")
        let reason = "Air is unreachable (asleep or offline?) — nothing was started."
        rig.personas.startOutcome = .unreachable(reason: reason, retryOn: Self.pro)
        rig.model.query = "task"
        rig.model.activateSelected()
        await waitUntil { if case .confirmingPersona = rig.model.routingState { true } else { false } }
        guard case .confirmingPersona(let retry) = rig.model.routingState else { return }
        #expect(retry.machineID == "local")
        #expect(retry.effect == .startNew)
        #expect(rig.model.footerNotice?.text == "\(reason) Return to start on Pro.")
        rig.personas.startOutcome = .started(paneId: "w1:p1")
        rig.model.activateSelected()
        await waitUntil { rig.personas.startCalls.count == 2 }
        #expect(rig.personas.startCalls.last == .init(name: "agentbar", text: "task", fresh: true, machine: "local"))
    }

    @Test func footerHintsNameTheModeKeys() {
        #expect(PanelFooterHints.text(for: .init(newWorkerMode: .pickingFolder)) == "↑↓ select   ↩ pick folder   esc cancel")
        #expect(PanelFooterHints.text(for: .init(newWorkerMode: .composingMachines)) == "↩ start fresh   ←→ machine   esc back")
    }
}
