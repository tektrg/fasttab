import Foundation
import Testing
@testable import AgentBar

/// A plan answer over the wire, through a scripted transport: nothing here can reach a real dashboard.
struct PlanSelectRequestTests {
    typealias F = PlanFixtures

    private let endpoint = DashboardEndpoint(baseURL: URL(string: "http://127.0.0.1:4799")!)

    private func body(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func aRowIsASelectWithItsNumberAndTheBoxAsRead() throws {
        let request = endpoint.planSelectRequest(paneId: "w1:p1", index: 2, text: nil, permission: F.box)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/permission")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.timeoutInterval == DashboardEndpoint.permissionTimeoutSeconds)
        let json = try body(request)
        #expect(Set(json.keys) == ["paneId", "choice", "index", "permission"])
        #expect(json["paneId"] as? String == "w1:p1")
        #expect(json["choice"] as? String == "select")
        #expect(json["index"] as? Int == 2)
        #expect(json["text"] == nil)
    }

    @Test func feedbackTextGoesOnlyWhenThereIsSome() throws {
        let request = endpoint.planSelectRequest(paneId: "w1:p1", index: 3, text: "Split step 2", permission: F.box)
        let json = try body(request)
        #expect(json["text"] as? String == "Split step 2")
        #expect(json["index"] as? Int == 3)
    }

    /// The dashboard's exact-match check compares each field: a plan box's `detail` is null and it
    /// carries `kind` and `planPath`, and every option label is echoed as the pane showed it.
    @Test func theBoxIsEchoedWithNullDetailKindPlanPathAndEveryLabel() throws {
        let json = try body(endpoint.planSelectRequest(paneId: "w1:p1", index: 1, text: nil, permission: F.box))
        let box = try #require(json["permission"] as? [String: Any])
        #expect(box["tool"] as? String == "ExitPlanMode")
        #expect(box["detail"] is NSNull)
        #expect(box["kind"] as? String == "plan")
        #expect(box["planPath"] as? String == F.planPath)
        #expect(box["title"] as? String == F.title)
        #expect(box["cursorIndex"] as? Int == 1)
        let options = try #require(box["options"] as? [[String: Any]])
        #expect(options.map { $0["label"] as? String } == ["Yes, and use auto mode", "Yes, manually approve edits", "Tell Claude what to change"])
        #expect(options.map { $0["index"] as? Int } == [1, 2, 3])
    }

    @Test func aBoxWithNoFooterEchoesPlanPathAsNull() throws {
        let box = PermissionPrompt(tool: "ExitPlanMode", detail: "", title: F.title, options: F.box.options, cursorIndex: 1, kind: .plan, planPath: nil)
        let json = try body(endpoint.planSelectRequest(paneId: "w1:p1", index: 1, text: nil, permission: box))
        let echoed = try #require(json["permission"] as? [String: Any])
        #expect(echoed["planPath"] is NSNull)
    }

    @Test func aToolBoxRequestIsUnchangedByThePlanFields() throws {
        let json = try body(endpoint.permissionRequest(paneId: "w1:p1", choice: .allow, permission: PermissionFixtures.bash))
        let box = try #require(json["permission"] as? [String: Any])
        #expect(box["detail"] as? String == "rm -rf /tmp/aptusfit-maestro-sim.lock")
        #expect(box["kind"] == nil)
        #expect(box["planPath"] == nil)
    }

    // MARK: - Through the source

    private func source(_ transport: some DashboardTransport) -> DashboardStatusSource {
        DashboardStatusSource(endpoint: endpoint, transport: transport)
    }

    @Test func anOkReplyIsSentAndTheRequestWentOutExactlyOnce() async {
        let transport = ScriptedDashboardTransport { _ in .body(Data(#"{"ok": true, "next": null}"#.utf8), statusCode: 200) }
        let result = await source(transport).selectPlanOption(paneId: "w1:p1", index: 2, text: nil, permission: F.box)
        #expect(result == .sent(next: nil))
        #expect(transport.requests.count == 1)
    }

    @Test func aRefusalCarriesTheDashboardsWords() async {
        let transport = ScriptedDashboardTransport { _ in .body(Data(#"{"ok": false, "error": "option 3 requires 'text'"}"#.utf8), statusCode: 200) }
        #expect(await source(transport).selectPlanOption(paneId: "w1:p1", index: 3, text: nil, permission: F.box) == .failed("option 3 requires 'text'"))
    }

    @Test func aTimeoutSaysItMayHaveGoneThroughAndDoesNotRetry() async {
        let transport = TimeoutTransport()
        let result = await source(transport).selectPlanOption(paneId: "w1:p1", index: 1, text: nil, permission: F.box)
        guard case .failed(let message) = result else {
            Issue.record("expected failed")
            return
        }
        #expect(message.contains("may have gone through"))
        #expect(transport.callCount == 1)
    }

    @Test func aDashboardWithoutTheEndpointIsUnsupported() async {
        let transport = ScriptedDashboardTransport { _ in .body(Data(#"{"error": "not found"}"#.utf8), statusCode: 404) }
        #expect(await source(transport).selectPlanOption(paneId: "w1:p1", index: 1, text: nil, permission: F.box) == .unsupported("not found"))
    }

    private final class TimeoutTransport: DashboardTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        var callCount: Int { lock.withLock { calls } }
        func response(for request: URLRequest) async throws -> (body: Data, statusCode: Int) {
            lock.withLock { calls += 1 }
            throw URLError(.timedOut)
        }
        func stream(for request: URLRequest) -> AsyncThrowingStream<Data, Error> { AsyncThrowingStream { $0.finish() } }
    }

    // MARK: - A plan box is never allowed or denied by wording

    @Test func aPlanBoxOffersNoAllowOrDenyChoiceEvenThoughItsRowsSayYes() {
        #expect(F.box.choices.isEmpty)
        for choice in PermissionChoice.allCases { #expect(F.box.option(for: choice) == nil) }
    }
}
