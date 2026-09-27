import Foundation
import Testing
@testable import AgentBar

struct DashboardEndpointTests {
    private func makeDefaults() -> UserDefaults {
        let suiteName = "test.agentbar.endpoint.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test func defaultsToLocalDashboard() {
        #expect(DashboardEndpoint.configured(defaults: makeDefaults()).baseURL.absoluteString == "http://127.0.0.1:4711")
    }

    @Test func displayAddressFollowsTheConfiguredEndpoint() {
        #expect(DashboardEndpoint(baseURL: DashboardEndpoint.defaultBaseURL).displayAddress == "127.0.0.1:4711")
        #expect(DashboardEndpoint(baseURL: URL(string: "http://10.0.0.5:9000")!).displayAddress == "10.0.0.5:9000")
        #expect(DashboardEndpoint(baseURL: URL(string: "https://dash.local")!).displayAddress == "dash.local")
    }

    @Test func honoursAConfiguredURL() {
        let defaults = makeDefaults()
        defaults.set(" http://10.0.0.5:9000 ", forKey: DashboardEndpoint.baseURLDefaultsKey)
        #expect(DashboardEndpoint.configured(defaults: defaults).baseURL.absoluteString == "http://10.0.0.5:9000")
    }

    @Test func ignoresAnInvalidConfiguredURL() {
        for bad in ["", "not a url", "ftp://host", "file:///tmp/x", "http://"] {
            let defaults = makeDefaults()
            defaults.set(bad, forKey: DashboardEndpoint.baseURLDefaultsKey)
            #expect(DashboardEndpoint.configured(defaults: defaults).baseURL == DashboardEndpoint.defaultBaseURL, "\(bad)")
        }
    }

    @Test func buildsTheDashboardPaths() {
        let endpoint = DashboardEndpoint(baseURL: DashboardEndpoint.defaultBaseURL)
        #expect(endpoint.stateRequest.url?.path == "/api/state")
        #expect(endpoint.eventsRequest.url?.path == "/api/events")
        #expect(endpoint.eventsRequest.value(forHTTPHeaderField: "Accept") == "text/event-stream")
        #expect(endpoint.paneScreenRequest(paneId: "w1:p3").url?.absoluteString
                == "http://127.0.0.1:4711/api/pane/screen?paneId=w1:p3&lines=100")
    }

    /// The dashboard holds a Claude hook prompt only while it sees AgentBar's own requests
    /// (`X-AgentBar: 1`) — the SSE stream and the `/api/state` poll fallback above all.
    @Test func everyRequestIdentifiesAgentBar() throws {
        let endpoint = DashboardEndpoint(baseURL: DashboardEndpoint.defaultBaseURL)
        let requests: [URLRequest] = [
            endpoint.stateRequest,
            endpoint.eventsRequest,
            endpoint.personasRequest,
            endpoint.focusRequest(paneId: "w1:p3"),
            endpoint.paneScreenRequest(paneId: "w1:p3"),
            endpoint.sessionActionRequest(.stop, rowId: "r1", confirmed: false),
            endpoint.messageRequest(rowId: "r1", text: "hi", confirmed: false),
            endpoint.agentTreeDetachRequest(child: "c"),
            endpoint.agentTreeAttachRequest(child: "c", parent: "p", confirmCrossProject: false),
            endpoint.personaStartRequest(persona: "p", text: "hi", fresh: false),
            try #require(endpoint.hookAnswerRequest(requestId: "hp1-ab", answer: .deciding(.deny))),
        ]
        for request in requests {
            #expect(request.value(forHTTPHeaderField: "X-AgentBar") == "1", "\(request.url?.path ?? "?")")
        }
    }
}
