import Foundation
import Testing
@testable import AgentBar

/// Stop/close over the wire. Every test goes through a scripted transport:
/// nothing here can reach a real dashboard.
struct SessionActionRequestTests {
    private let endpoint = DashboardEndpoint(baseURL: URL(string: "http://127.0.0.1:4799")!)

    private func makeSource(_ transport: ScriptedDashboardTransport) -> DashboardStatusSource {
        DashboardStatusSource(endpoint: endpoint, transport: transport)
    }

    private func reply(_ json: String, status: Int = 200) -> ScriptedDashboardTransport {
        ScriptedDashboardTransport { _ in .body(Data(json.utf8), statusCode: status) }
    }

    private func body(of request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func stopIsAPostToTheStopEndpointAsThePoActor() throws {
        let request = endpoint.sessionActionRequest(.stop, rowId: "row-1", confirmed: false)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/session/stop")
        let json = try body(of: request)
        #expect(json["rowId"] as? String == "row-1")
        #expect(json["actor"] as? String == "po")
        #expect(json["confirm"] == nil)
    }

    @Test func confirmIsSentOnlyOnTheConfirmedPress() throws {
        let request = endpoint.sessionActionRequest(.close, rowId: "row-1", confirmed: true)
        #expect(request.url?.path == "/api/session/close")
        #expect(try body(of: request)["confirm"] as? Bool == true)
    }

    @Test func successIsReported() async {
        let outcome = await makeSource(reply(#"{"ok": true, "state": "stopped (3 procs; 0 sigkilled)", "reason": ""}"#))
            .perform(.stop, rowId: "r", confirmed: false)
        #expect(outcome == .succeeded)
    }

    @Test func needsConfirmCarriesTheServersReason() async {
        let outcome = await makeSource(reply(#"{"ok": false, "needsConfirm": true, "reason": "blocked · 9 uncommitted files"}"#))
            .perform(.stop, rowId: "r", confirmed: false)
        #expect(outcome == .needsConfirmation(reason: "blocked · 9 uncommitted files"))
    }

    @Test func aRefusalIsReportedWithItsError() async {
        // The dashboard answers refusals with HTTP 400 and a JSON error.
        let outcome = await makeSource(reply(#"{"ok": false, "error": "refused: already stopped"}"#, status: 400))
            .perform(.stop, rowId: "r", confirmed: false)
        #expect(outcome == .failed("refused: already stopped"))
    }

    @Test func aReplyWithNoUsableAnswerIsAFailureNotASuccess() async {
        let outcome = await makeSource(reply("{}")).perform(.close, rowId: "r", confirmed: false)
        guard case .failed = outcome else {
            Issue.record("expected failure, got \(outcome)")
            return
        }
    }

    @Test func aGarbledReplyIsAFailure() async {
        let outcome = await makeSource(reply("<html>oops</html>")).perform(.stop, rowId: "r", confirmed: false)
        guard case .failed(let message) = outcome else {
            Issue.record("expected failure")
            return
        }
        #expect(message.contains("unreadable"))
    }

    @Test func anUnreachableDashboardIsAFailure() async {
        let outcome = await makeSource(ScriptedDashboardTransport { _ in .fail }).perform(.stop, rowId: "r", confirmed: false)
        #expect(outcome == .failed("Can't reach the status dashboard."))
    }

    @Test func theRequestsGoOnlyToTheConfiguredAddress() async {
        let transport = reply(#"{"ok": true}"#)
        _ = await makeSource(transport).perform(.stop, rowId: "r", confirmed: false)
        #expect(transport.requests.map { $0.url?.host } == ["127.0.0.1"])
        #expect(transport.requests.map { $0.url?.port } == [4799])
    }
}
