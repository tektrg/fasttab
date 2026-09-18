import Foundation
import Testing
@testable import AgentBar

struct DashboardAddressTests {
    @Test func acceptsHttpAndHttpsAndTrimsWhitespace() {
        #expect(DashboardAddress.validate("http://127.0.0.1:4711") == .valid(URL(string: "http://127.0.0.1:4711")!))
        #expect(DashboardAddress.validate("  https://dash.local  ") == .valid(URL(string: "https://dash.local")!))
        #expect(DashboardAddress.validate("HTTP://Host:1") == .valid(URL(string: "HTTP://Host:1")!))
    }

    @Test func rejectsWithAPlainEnglishReason() {
        let reasons = ["", "   ", "127.0.0.1:4711", "ftp://host", "file:///tmp/x", "http://", "not a url"].map(DashboardAddress.validate)
        for reason in reasons {
            guard case .invalid(let text) = reason else { Issue.record("expected invalid"); continue }
            #expect(text.hasSuffix("."))
        }
    }

    @Test func theLaunchTimeReadAgreesWithTheFieldRule() {
        let defaults = makeScratchDefaults("address")
        for text in ["http://10.0.0.5:9000", "ftp://x", "", "http://"] {
            defaults.set(text, forKey: DashboardEndpoint.baseURLDefaultsKey)
            let expected: URL = if case .valid(let url) = DashboardAddress.validate(text) { url } else { DashboardEndpoint.defaultBaseURL }
            #expect(DashboardEndpoint.configured(defaults: defaults).baseURL == expected, "\(text)")
        }
    }
}

struct DashboardConnectionTesterTests {
    private let url = URL(string: "http://127.0.0.1:4711")!

    private func result(_ reply: ScriptedDashboardTransport.Reply) async -> DashboardConnectionTester.Result {
        await DashboardConnectionTester(transport: ScriptedDashboardTransport { _ in reply }).test(url)
    }

    @Test func reportsTheAgentCountFromTheState() async {
        let outcome = await result(.body(StatusFixtures.data("state-healthy")))
        guard case .connected(let count) = outcome else { Issue.record("expected connected, got \(outcome)"); return }
        #expect(count > 0)
        #expect(outcome.message == "Connected — \(count) agents")
    }

    @Test func aSingleAgentIsSingular() {
        #expect(DashboardConnectionTester.Result.connected(agentCount: 1).message == "Connected — 1 agent")
        #expect(DashboardConnectionTester.Result.connected(agentCount: 0).message == "Connected — 0 agents")
    }

    @Test func asksTheStateEndpointOfTheGivenAddress() async {
        let transport = ScriptedDashboardTransport { _ in .body(StatusFixtures.data("state-healthy")) }
        _ = await DashboardConnectionTester(transport: transport).test(URL(string: "http://10.0.0.5:9000")!)
        #expect(transport.requests.map { $0.url?.absoluteString } == ["http://10.0.0.5:9000/api/state"])
    }

    @Test func anUnreachableAddressSaysSo() async {
        let outcome = await result(.fail)
        #expect(outcome == .failed("Can't reach 127.0.0.1:4711. Is the dashboard running?"))
    }

    @Test func anErrorStatusIsReported() async {
        let outcome = await result(.body(Data("nope".utf8), statusCode: 500))
        #expect(outcome == .failed("127.0.0.1:4711 answered with an error (HTTP 500). Is that the chief dashboard?"))
    }

    @Test func aReplyThatIsNotTheDashboardIsReported() async {
        let outcome = await result(.body(Data("<html>hi</html>".utf8)))
        #expect(outcome == .failed("127.0.0.1:4711 answered, but not like the chief dashboard."))
    }
}
