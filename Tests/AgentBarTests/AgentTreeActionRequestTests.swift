import Foundation
import Testing
@testable import AgentBar

/// Action -> request mapping for the agent hierarchy, and the reply -> outcome mapping on the way
/// back. Every test goes through a scripted transport: nothing here can reach a real dashboard.
struct AgentTreeActionRequestTests {
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

    // MARK: - Request shape

    @Test func attachIsAPostWithChildParentAndConfirmFlag() throws {
        let request = endpoint.agentTreeAttachRequest(child: "w1", parent: "c1", confirmCrossProject: false)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/agent-tree/attach")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let json = try body(of: request)
        #expect(json["child"] as? String == "w1")
        #expect(json["parent"] as? String == "c1")
        #expect(json["confirmCrossProject"] as? Bool == false)
        #expect(Set(json.keys) == ["child", "parent", "confirmCrossProject"])
    }

    @Test func confirmCrossProjectIsSentTrueOnlyOnTheConfirmedRetry() throws {
        let request = endpoint.agentTreeAttachRequest(child: "w1", parent: "c1", confirmCrossProject: true)
        #expect(try body(of: request)["confirmCrossProject"] as? Bool == true)
    }

    @Test func detachIsAPostWithJustTheChild() throws {
        let request = endpoint.agentTreeDetachRequest(child: "w1")
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/agent-tree/detach")
        let json = try body(of: request)
        #expect(json["child"] as? String == "w1")
        #expect(Set(json.keys) == ["child"])
    }

    // MARK: - Attach replies

    @Test func attachSuccessWithNoWarning() async {
        let outcome = await makeSource(reply(#"{"ok": true, "warning": null}"#))
            .attachToTree(child: "w1", parent: "c1", confirmCrossProject: false)
        #expect(outcome == .attached(warning: nil))
    }

    @Test func attachSuccessCarriesAWarningVerbatim() async {
        let outcome = await makeSource(reply(#"{"ok": true, "warning": "c1 is on a different machine"}"#))
            .attachToTree(child: "w1", parent: "c1", confirmCrossProject: false)
        #expect(outcome == .attached(warning: "c1 is on a different machine"))
    }

    @Test func crossProjectNeedsConfirmCarriesTheServersMessage() async {
        let json = #"{"error": "cross-project", "needsConfirm": true, "message": "w1 is in ProjectA, c1 is in ProjectB. Attach anyway?"}"#
        let outcome = await makeSource(reply(json, status: 409))
            .attachToTree(child: "w1", parent: "c1", confirmCrossProject: false)
        #expect(outcome == .needsConfirm(message: "w1 is in ProjectA, c1 is in ProjectB. Attach anyway?"))
    }

    @Test func cycleIsRefusedWithTheServersMessage() async {
        let json = #"{"error": "cycle", "message": "c1 already reports (indirectly) to w1"}"#
        let outcome = await makeSource(reply(json, status: 400)).attachToTree(child: "w1", parent: "c1", confirmCrossProject: false)
        #expect(outcome == .refused(message: "c1 already reports (indirectly) to w1"))
    }

    @Test func twoLevelIsRefused() async {
        let json = #"{"error": "two-level", "message": "c1 is itself a chief"}"#
        let outcome = await makeSource(reply(json, status: 400)).attachToTree(child: "w1", parent: "c1", confirmCrossProject: false)
        #expect(outcome == .refused(message: "c1 is itself a chief"))
    }

    @Test func unknownAgentIsRefused() async {
        let json = #"{"error": "unknown-agent", "message": "no such agent: w9"}"#
        let outcome = await makeSource(reply(json, status: 400)).attachToTree(child: "w9", parent: "c1", confirmCrossProject: false)
        #expect(outcome == .refused(message: "no such agent: w9"))
    }

    @Test func selfIsRefused() async {
        let json = #"{"error": "self", "message": "an agent can't report to itself"}"#
        let outcome = await makeSource(reply(json, status: 400)).attachToTree(child: "w1", parent: "w1", confirmCrossProject: false)
        #expect(outcome == .refused(message: "an agent can't report to itself"))
    }

    @Test func anUnreadableAttachReplyIsAFailureNotASuccess() async {
        let outcome = await makeSource(reply("not json")).attachToTree(child: "w1", parent: "c1", confirmCrossProject: false)
        guard case .failed = outcome else {
            Issue.record("expected a failure, got \(outcome)")
            return
        }
    }

    @Test func anUnreachableDashboardIsAFailureForAttach() async {
        let outcome = await makeSource(ScriptedDashboardTransport { _ in .fail })
            .attachToTree(child: "w1", parent: "c1", confirmCrossProject: false)
        #expect(outcome == .failed("Can't reach the status dashboard."))
    }

    @Test func aTimeoutOnAttachSaysItMayHaveGoneThrough() async {
        struct TimeoutTransport: DashboardTransport {
            func response(for request: URLRequest) async throws -> (body: Data, statusCode: Int) { throw URLError(.timedOut) }
            func stream(for request: URLRequest) -> AsyncThrowingStream<Data, Error> { AsyncThrowingStream { $0.finish() } }
        }
        let outcome = await DashboardStatusSource(endpoint: endpoint, transport: TimeoutTransport())
            .attachToTree(child: "w1", parent: "c1", confirmCrossProject: false)
        guard case .failed(let message) = outcome else {
            Issue.record("expected a failure, got \(outcome)")
            return
        }
        #expect(message.contains("may have gone through"))
    }

    // MARK: - Detach replies

    @Test func detachSuccess() async {
        let outcome = await makeSource(reply(#"{"ok": true}"#)).detachFromTree(child: "w1")
        #expect(outcome == .detached)
    }

    @Test func detachFailureCarriesTheServersWords() async {
        let outcome = await makeSource(reply(#"{"ok": false, "error": "no such agent"}"#)).detachFromTree(child: "w1")
        #expect(outcome == .failed("no such agent"))
    }

    @Test func anUnreachableDashboardIsAFailureForDetach() async {
        let outcome = await makeSource(ScriptedDashboardTransport { _ in .fail }).detachFromTree(child: "w1")
        #expect(outcome == .failed("Can't reach the status dashboard."))
    }
}
