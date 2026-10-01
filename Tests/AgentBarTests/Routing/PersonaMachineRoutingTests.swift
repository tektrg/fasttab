import Foundation
import Testing
@testable import AgentBar

/// Persona machine routing ("persona start on Air"): the `runsOn`/`machines` wire shape, the
/// confirm row's machine chips (default + Left/Right), the `machine` the start POST carries, the
/// unreachable reply's one-press retry offer, and Settings' "Runs on" save. Fakes only.
@MainActor
struct PersonaMachineRoutingTests {
    typealias F = AgentListFixtures

    private static let pro = PersonaMachine(id: "local", label: "Pro")
    private static let air = PersonaMachine(id: "air-m1", label: "Air")
    private static let hostile = "$(echo INJECTED)"

    private static func persona(runsOn: String? = "air-m1", machines: [PersonaMachine]? = [pro, air],
                                mainRowId: String? = nil) -> Persona {
        var persona = PersonaFixtures.persona("air-notes", mainRowId: mainRowId, idleStart: .fresh)
        persona.runsOn = runsOn
        persona.machines = machines
        return persona
    }

    // MARK: - Decoding

    @Test func decodesRunsOnAndMachines() throws {
        let json = """
        [{"name": "air-notes", "address": "air-m1:~/notes", "description": "d", "routesWhen": [], "notFor": [],
          "offline": false, "mainRowId": null, "sessionRowIds": [], "idleStart": "fresh",
          "runsOn": "air-m1", "machines": [{"id": "local", "label": "Pro"}, {"id": "air-m1", "label": "Air"}]}]
        """
        let decoded = try JSONDecoder().decode([Persona].self, from: Data(json.utf8))
        #expect(decoded.first?.runsOn == "air-m1")
        #expect(decoded.first?.machines == [Self.pro, Self.air])
    }

    @Test func anOlderDashboardWithoutMachineRoutingStillDecodesAndShowsNoChips() throws {
        let json = """
        [{"name": "a", "address": "local:~/a", "description": "d", "routesWhen": [], "notFor": [],
          "offline": false, "sessionRowIds": []}]
        """
        let list = try JSONDecoder().decode([Persona].self, from: Data(json.utf8))
        let decoded = try #require(list.first)
        #expect(decoded.runsOn == nil && decoded.machines == nil)
        let pick = PersonaPick(persona: decoded, confidence: 1, mainSession: .absent)
        #expect(pick.machineChips.isEmpty)
        #expect(pick.startMachineID == nil)
    }

    @Test func registryDecodesMachinesAndRunsOn() throws {
        let json = """
        {"globalInstructions": "", "defaultGlobalInstructions": "", "hiddenSuggestions": [],
         "machines": [{"id": "local", "label": "Pro"}, {"id": "air-m1", "label": "Air"}],
         "personas": [{"address": "local:~/a", "name": "a", "description": "", "routesWhen": [], "notFor": [],
                       "extraInstructions": "", "idle": "resume", "resumeWithinDays": 3, "start": "in-place",
                       "runsOn": "air-m1", "hidden": false, "offered": false}]}
        """
        let registry = try JSONDecoder().decode(PersonaRegistry.self, from: Data(json.utf8))
        #expect(registry.machines == [Self.pro, Self.air])
        #expect(registry.personas.first?.runsOn == "air-m1")
        let first = try #require(registry.personas.first)
        #expect(PersonaDraft(editing: first).runsOn == "air-m1")
    }

    // MARK: - Chips

    @Test func chipsDefaultToRunsOnAndArrowsMoveClampedAtTheEnds() {
        var pick = PersonaPick(persona: Self.persona(), confidence: 1, mainSession: .absent)
        #expect(pick.machineChips == [Self.pro, Self.air])
        #expect(pick.machineID == "air-m1")
        do { let moved = pick.moveMachine(by: 1); #expect(moved) }
        #expect(pick.machineID == "air-m1")
        do { let moved = pick.moveMachine(by: -1); #expect(moved) }
        #expect(pick.machineID == "local")
        do { let moved = pick.moveMachine(by: -1); #expect(moved) }
        #expect(pick.machineID == "local")
    }

    @Test func noChipsForASendToALiveMainOrASingleMachine() {
        var toMain = PersonaPick(persona: Self.persona(), confidence: 1, mainSession: .ready(agentID: "w"))
        #expect(toMain.machineChips.isEmpty)
        do { let moved = toMain.moveMachine(by: 1); #expect(!moved) }
        let single = PersonaPick(persona: Self.persona(runsOn: "local", machines: [Self.pro]), confidence: 1, mainSession: .absent)
        #expect(single.machineChips.isEmpty)
    }

    // MARK: - Wire

    @Test func startRequestCarriesTheMachineOnlyWhenGiven() throws {
        let endpoint = DashboardEndpoint(baseURL: URL(string: "http://127.0.0.1:4799")!)
        func body(_ machine: String?) throws -> [String: Any] {
            let data = try #require(endpoint.personaStartRequest(persona: "air-notes", text: Self.hostile, fresh: true, machine: machine).httpBody)
            let object = try JSONSerialization.jsonObject(with: data)
            return try #require(object as? [String: Any])
        }
        #expect(try body("air-m1")["machine"] as? String == "air-m1")
        #expect(try body("air-m1")["text"] as? String == Self.hostile)
        #expect(try body(nil)["machine"] == nil)
    }

    @Test func anUnreachableReplyDecodesWithItsRetryMachine() async {
        let json = #"{"ok": false, "error": "Air is unreachable (asleep or offline?) — nothing was started.", "unreachable": true, "retryOn": {"id": "local", "label": "Pro"}}"#
        let transport = ScriptedDashboardTransport { _ in .body(Data(json.utf8), statusCode: 200) }
        let source = DashboardStatusSource(endpoint: DashboardEndpoint(baseURL: URL(string: "http://127.0.0.1:4799")!), transport: transport)
        let outcome = await source.startPersona("air-notes", text: "hi", fresh: true, machine: "air-m1")
        #expect(outcome == .unreachable(reason: "Air is unreachable (asleep or offline?) — nothing was started.", retryOn: Self.pro))
    }

    // MARK: - Panel model

    private struct Rig {
        let model: AgentPanelModel
        let personas: FakePersonaDirectorySource
    }

    private func routedRig(_ persona: Persona) async -> Rig {
        let defaults = makeScratchDefaults("persona-machine-\(UUID().uuidString)")
        let model = AgentPanelModel(
            store: FrecencyStore(defaults: defaults),
            triageStore: TriageStore(defaults: defaults),
            routedNoteStore: RoutedNoteStore(defaults: defaults),
            now: { F.now }
        )
        model.statusSource = MessageFakeSource()
        let personaSource = FakePersonaDirectorySource()
        personaSource.personas = [persona]
        model.personaSource = personaSource
        let keyStore = FakeRoutingAPIKeyStore()
        try? keyStore.set("sk-test")
        model.routingAPIKeyStore = keyStore
        model.applyRouting(RoutingSettings(modelID: "~typesafe/jev-latest", afterRouting: .confirmFirst))
        let client = FakeJevRoutingClient()
        client.outcome = .picked(agentID: "persona:\(persona.name)", confidence: 0.9)
        model.makeRoutingClient = { _, _, _ in client }
        model.receive(F.snapshot([]))
        model.query = Self.hostile
        model.startRouting()
        await waitUntil { model.routingState != .loading }
        return Rig(model: model, personas: personaSource)
    }

    private func shownPick(_ rig: Rig) -> PersonaPick? {
        guard case .confirmingPersona(let pick) = rig.model.routingState else { return nil }
        return pick
    }

    @Test func arrowsPickAMachineAndTheStartCarriesIt() async {
        let rig = await routedRig(Self.persona())
        #expect(shownPick(rig)?.machineID == "air-m1")
        #expect(rig.model.movePersonaMachine(by: -1))
        #expect(shownPick(rig)?.machineID == "local")
        rig.personas.startOutcome = .started(paneId: "w1:p1")
        rig.model.activateSelected()
        await waitUntil { !rig.personas.startCalls.isEmpty }
        #expect(rig.personas.startCalls == [.init(name: "air-notes", text: Self.hostile, fresh: true, machine: "local")])
    }

    @Test func arrowsAreNotClaimedWithoutChips() async {
        let rig = await routedRig(Self.persona(runsOn: nil, machines: nil))
        #expect(!rig.model.movePersonaMachine(by: 1))
    }

    @Test func unreachableOffersOneReturnRetryOnTheOtherMachineNeverSilently() async {
        let rig = await routedRig(Self.persona())
        let reason = "Air is unreachable (asleep or offline?) — nothing was started."
        rig.personas.startOutcome = .unreachable(reason: reason, retryOn: Self.pro)
        rig.model.activateSelected()
        await waitUntil { if case .confirmingPersona = rig.model.routingState { true } else { false } }

        #expect(rig.personas.startCalls.count == 1)
        #expect(shownPick(rig)?.machineID == "local")
        #expect(rig.model.footerNotice?.text == "\(reason) Return to start on Pro.")
        #expect(rig.model.query == Self.hostile)

        rig.personas.startOutcome = .started(paneId: "w1:p1")
        rig.model.activateSelected()
        await waitUntil { rig.personas.startCalls.count == 2 }
        #expect(rig.personas.startCalls.last?.machine == "local")
    }

    // MARK: - Settings

    @Test func editingSendsTheChosenRunsOn() async throws {
        let registryJSON = """
        {"ok": true, "globalInstructions": "G", "defaultGlobalInstructions": "G", "hiddenSuggestions": [],
         "machines": [{"id": "local", "label": "Pro"}, {"id": "air-m1", "label": "Air"}],
         "personas": [{"address": "local:~/app", "name": "app", "description": "d", "routesWhen": [], "notFor": [],
                       "extraInstructions": "", "idle": "resume", "resumeWithinDays": 3, "start": "in-place",
                       "runsOn": "local", "hidden": false, "offered": true}]}
        """
        let transport = ScriptedDashboardTransport { request in
            switch request.url?.path {
            case "/api/personas/registry": .body(Data(registryJSON.utf8))
            case "/api/personas": .body(Data("{\"ok\": true, \"registry\": \(registryJSON)}".utf8))
            default: .body(Data("[]".utf8))
            }
        }
        let client = PersonaRegistryClient(baseURL: URL(string: "http://127.0.0.1:4799")!, transport: transport)
        let model = PersonaSettingsModel { client }
        await model.reload()
        let persona = try #require(model.registry?.personas.first)
        model.startEditing(persona)
        #expect(model.editor?.draft.runsOn == "local")
        model.editor?.draft.runsOn = "air-m1"
        await model.saveEditor()
        let request = try #require(transport.requests.last { $0.httpMethod == "POST" })
        let data = try #require(request.httpBody)
        let object = try JSONSerialization.jsonObject(with: data)
        let body = try #require(object as? [String: Any])
        #expect(body["action"] as? String == "edit")
        #expect((body["fields"] as? [String: Any])?["runsOn"] as? String == "air-m1")
    }
}
