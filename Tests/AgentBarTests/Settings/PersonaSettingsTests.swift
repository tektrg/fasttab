import Foundation
import Testing
@testable import AgentBar

/// Settings > Personas over a scripted transport: nothing here can reach a real dashboard.
@MainActor
struct PersonaSettingsTests {
    private static let baseURL = URL(string: "http://127.0.0.1:4799")!

    private nonisolated static let registryJSON = """
    {"ok": true, "globalInstructions": "G", "defaultGlobalInstructions": "G",
     "personas": [{"address": "local:~/01_Project/app", "name": "app", "description": "",
                   "routesWhen": ["a"], "notFor": [], "extraInstructions": "", "idle": "resume",
                   "resumeWithinDays": 3, "start": "in-place", "hidden": false, "offered": false}],
     "hiddenSuggestions": ["local:~/old"]}
    """

    private nonisolated static let suggestionsJSON = """
    [{"address": "local:~/01_Project/ssv-bi-platform", "lastActive": 1790000000, "sessionCount": 4,
      "draftDescription": "BI — dashboards"}]
    """

    private static func client(_ respond: @escaping @Sendable (URLRequest) -> ScriptedDashboardTransport.Reply)
        -> (PersonaRegistryClient, ScriptedDashboardTransport) {
        let transport = ScriptedDashboardTransport(respond: respond)
        return (PersonaRegistryClient(baseURL: baseURL, transport: transport), transport)
    }

    private static func healthyDashboard(post: String = "{\"ok\": true, \"registry\": \(registryJSON)}")
        -> @Sendable (URLRequest) -> ScriptedDashboardTransport.Reply {
        { request in
            switch request.url?.path {
            case "/api/personas/registry": .body(Data(registryJSON.utf8))
            case "/api/personas/suggestions": .body(Data(suggestionsJSON.utf8))
            case "/api/personas": .body(Data(post.utf8))
            default: .body(Data(#"{"error": "not found"}"#.utf8), statusCode: 404)
            }
        }
    }

    private static func postedBody(_ transport: ScriptedDashboardTransport) -> [String: Any]? {
        guard let request = transport.requests.last(where: { $0.httpMethod == "POST" }),
              let body = request.httpBody else { return nil }
        return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }

    // MARK: - Client

    @Test func a404SaysTheDashboardIsTooOld() async {
        let (client, _) = Self.client { _ in .body(Data(#"{"error": "not found"}"#.utf8), statusCode: 404) }
        #expect(await client.loadRegistry() == .failure(PersonaRegistryFailure(PersonaRegistryClient.dashboardTooOldMessage)))
        #expect(PersonaRegistryClient.dashboardTooOldMessage.contains("update"))
    }

    @Test func anUnreachableDashboardSaysSo() async {
        let (client, _) = Self.client { _ in .fail }
        #expect(await client.loadSuggestions() == .failure(PersonaRegistryFailure("Can't reach the dashboard at 127.0.0.1:4799. Is it running?")))
    }

    @Test func aRefusalShowsTheDashboardsOwnWords() async {
        let (client, _) = Self.client { _ in .body(Data(#"{"ok": false, "error": "Another persona is already named app."}"#.utf8)) }
        #expect(await client.apply(.hide(address: "local:~/x")) == .failure(PersonaRegistryFailure("Another persona is already named app.")))
    }

    @Test func postsAreJSONWithTheAgentBarHeader() async {
        let (client, transport) = Self.client(Self.healthyDashboard())
        _ = await client.apply(.setGlobalInstructions(""))
        let request = transport.requests.last
        #expect(request?.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request?.value(forHTTPHeaderField: DashboardEndpoint.clientHeaderName) == DashboardEndpoint.clientHeaderValue)
        #expect(request?.url?.path == "/api/personas")
        #expect(Self.postedBody(transport)?["action"] as? String == "setGlobalInstructions")
    }

    @Test func decodesTheRegistry() async throws {
        let (client, _) = Self.client(Self.healthyDashboard())
        let registry = try await client.loadRegistry().get()
        #expect(registry.personas.map(\.name) == ["app"])
        #expect(registry.hiddenSuggestions == ["local:~/old"])
        #expect(registry.usesDefaultGlobalInstructions)
    }

    // MARK: - Draft

    @Test func adoptingPrefillsNameAndDescriptionFromTheFolder() {
        let suggestion = PersonaSuggestion(address: "local:~/01_Project/My Repo", lastActive: 0, sessionCount: 1,
                                           draftDescription: "Repo — does things")
        let draft = PersonaDraft(adopting: suggestion)
        #expect(draft.name == "my-repo")
        #expect(draft.description == "Repo — does things")
    }

    @Test func listFieldsAreOnePerLineWithBlanksDropped() {
        var draft = PersonaDraft()
        draft.name = " app "
        draft.routesWhenText = "bugs\n\n  releases \n"
        let fields = draft.wireFields
        #expect(fields["name"] as? String == "app")
        #expect(fields["routesWhen"] as? [String] == ["bugs", "releases"])
        #expect(fields["idle"] as? String == "resume")
    }

    // MARK: - Model

    @Test func reloadShowsTheFailureInsteadOfAnEmptyList() async {
        let (client, _) = Self.client { _ in .body(Data(#"{"error": "not found"}"#.utf8), statusCode: 404) }
        let model = PersonaSettingsModel { client }
        await model.reload()
        #expect(model.registry == nil)
        #expect(model.loadError == PersonaRegistryClient.dashboardTooOldMessage)
    }

    @Test func adoptingSendsTheSuggestionAddressAndClosesTheEditor() async throws {
        let (client, transport) = Self.client(Self.healthyDashboard())
        let model = PersonaSettingsModel { client }
        await model.reload()
        let suggestion = try #require(model.suggestions.first)
        model.startAdopting(suggestion)
        model.editor?.draft.name = "bi"
        await model.saveEditor()
        let body = try #require(Self.postedBody(transport))
        #expect(body["action"] as? String == "adopt")
        #expect(body["address"] as? String == "local:~/01_Project/ssv-bi-platform")
        #expect((body["persona"] as? [String: Any])?["description"] as? String == "BI — dashboards")
        #expect(model.editor == nil)
        #expect(model.suggestions.isEmpty)
    }

    @Test func aRefusedSaveKeepsTheEditorOpenWithTheReason() async throws {
        let (client, _) = Self.client(Self.healthyDashboard(post: #"{"ok": false, "error": "Name must be 1-40 letters."}"#))
        let model = PersonaSettingsModel { client }
        await model.reload()
        model.startEditing(try #require(model.registry?.personas.first))
        await model.saveEditor()
        #expect(model.editor?.error == "Name must be 1-40 letters.")
        #expect(model.editor?.isSaving == false)
    }

    @Test func aBlankNameIsCaughtBeforeAnyRequest() async throws {
        let (client, transport) = Self.client(Self.healthyDashboard())
        let model = PersonaSettingsModel { client }
        await model.reload()
        model.startEditing(try #require(model.registry?.personas.first))
        model.editor?.draft.name = "  "
        await model.saveEditor()
        #expect(model.editor?.error == "Give the persona a name.")
        #expect(transport.requests.allSatisfy { $0.httpMethod != "POST" })
    }

    @Test func editSendsTheAddressNotAPath() async throws {
        let (client, transport) = Self.client(Self.healthyDashboard())
        let model = PersonaSettingsModel { client }
        await model.reload()
        model.startEditing(try #require(model.registry?.personas.first))
        await model.saveEditor()
        let body = try #require(Self.postedBody(transport))
        #expect(body["action"] as? String == "edit")
        #expect(body["persona"] as? String == "local:~/01_Project/app")
    }

    @Test func hidingASuggestionRemovesItAndAFailureIsShown() async throws {
        let (client, _) = Self.client(Self.healthyDashboard())
        let model = PersonaSettingsModel { client }
        await model.reload()
        await model.hideSuggestion(try #require(model.suggestions.first))
        #expect(model.suggestions.isEmpty)

        let (failing, _) = Self.client { _ in .fail }
        let offline = PersonaSettingsModel { failing }
        await offline.remove(try #require(model.registry?.personas.first))
        #expect(offline.actionError == "Can't reach the dashboard at 127.0.0.1:4799. Is it running?")
    }
}
