import Foundation
import Testing
@testable import AgentBar

/// `DashboardStatusSource.startPersona` over a scripted transport: nothing here can reach a real dashboard.
struct PersonaStartRequestTests {
    private func startOutcome(_ json: String, status: Int) async -> PersonaStartOutcome {
        let transport = ScriptedDashboardTransport { _ in .body(Data(json.utf8), statusCode: status) }
        let source = DashboardStatusSource(endpoint: DashboardEndpoint(baseURL: URL(string: "http://127.0.0.1:4799")!), transport: transport)
        return await source.startPersona("air-notes", text: "triage the inbox", fresh: false)
    }

    @Test func aDashboardWithoutTheEndpointSaysToUpdateItNotTheBareNotFound() async {
        #expect(await startOutcome(#"{"error": "not found"}"#, status: 404) == .failed(DashboardPersonaStartResponse.endpointMissingMessage))
        #expect(DashboardPersonaStartResponse.endpointMissingMessage == "This dashboard can't start personas yet — update it.")
    }

    @Test func aRefusalStillShowsTheDashboardsOwnReason() async {
        #expect(await startOutcome(#"{"ok": false, "error": "herdr couldn't create a pane."}"#, status: 200) == .failed("herdr couldn't create a pane."))
    }

    @Test func aStartedReplyIsStarted() async {
        #expect(await startOutcome(#"{"ok": true, "paneId": "w9:p1", "mode": "started"}"#, status: 200) == .started(paneId: "w9:p1"))
    }
}
