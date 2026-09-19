import Foundation
import Testing
@testable import AgentBar

/// Deciding over the wire. Every test goes through a scripted transport: nothing here can reach a real dashboard.
struct PermissionRequestTests {
    typealias P = PermissionFixtures

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

    private func decide(_ transport: ScriptedDashboardTransport, choice: PermissionChoice = .allow) async -> PermissionResult {
        await makeSource(transport).permission(paneId: "w1:p1", choice: choice, permission: P.bash)
    }

    // MARK: - Request shape

    @Test func aDecisionIsAPostOfThePaneTheChoiceAndTheBoxAsRead() throws {
        let request = endpoint.permissionRequest(paneId: "w1:p1", choice: .deny, permission: P.bash)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/permission")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let json = try body(of: request)
        #expect(Set(json.keys) == ["paneId", "choice", "permission"])
        #expect(json["paneId"] as? String == "w1:p1")
        #expect(json["choice"] as? String == "deny")
    }

    @Test func theChoicesAreTheDashboardsThreeWords() throws {
        for (choice, word) in [(PermissionChoice.allow, "allow"), (.allowAlways, "allow-always"), (.deny, "deny")] {
            let request = endpoint.permissionRequest(paneId: "w1:p1", choice: choice, permission: P.bash)
            #expect(try body(of: request)["choice"] as? String == word)
        }
    }

    /// The dashboard refuses unless the box it reads equals the echoed one letter for letter:
    /// what it sent us goes back untouched, whatever is in the strings.
    @Test func theBoxIsEchoedBackByteForByteEvenWithAwkwardText() throws {
        let odd = PermissionPrompt(
            tool: "Bash",
            detail: "echo \"quoted\" \\ back/slash 'single' ✓ đ  two  spaces\ttab   ",
            title: "Do you want to proceed?",
            options: [.init(index: 1, label: "Yes"), .init(index: 2, label: "Yes, and don't ask again for echo commands in /tmp/ü"), .init(index: 3, label: "No, and tell Claude  what (esc)")],
            cursorIndex: 2
        )
        let sent = try #require(JSONSerialization.jsonObject(with: Data(P.json(odd).utf8)) as? NSDictionary)
        let decoded = try #require(try JSONDecoder().decode(DashboardPermission.self, from: Data(P.json(odd).utf8)).prompt)
        let echoed = try #require(try body(of: endpoint.permissionRequest(paneId: "w1:p1", choice: .allow, permission: decoded))["permission"] as? NSDictionary)
        #expect(echoed == sent)
    }

    @Test func theOptionsKeepTheirOrderAndNumbers() throws {
        let box = try #require(try body(of: endpoint.permissionRequest(paneId: "w1:p1", choice: .allow, permission: P.bash))["permission"] as? [String: Any])
        let options = try #require(box["options"] as? [[String: Any]])
        #expect(options.compactMap { $0["index"] as? Int } == [1, 2, 3])
        #expect(options.compactMap { $0["label"] as? String } == P.bash.options.map(\.label))
        #expect(box["cursorIndex"] as? Int == 1)
    }

    @Test func aBoxWithoutACursorSendsNoCursor() throws {
        let box = PermissionPrompt(tool: "Bash", detail: "ls", title: "Do you want to proceed?", options: P.bash.options, cursorIndex: nil)
        let sent = try #require(try body(of: endpoint.permissionRequest(paneId: "w1:p1", choice: .allow, permission: box))["permission"] as? [String: Any])
        #expect(sent["cursorIndex"] == nil)
    }

    @Test func theRequestWaitsLongEnoughForThePressAndTheReRead() {
        #expect(endpoint.permissionRequest(paneId: "w1:p1", choice: .allow, permission: P.bash).timeoutInterval >= 30)
    }

    // MARK: - Replies

    @Test func successWithNothingNext() async {
        #expect(await decide(reply(#"{"ok": true, "next": null}"#)) == .sent(next: nil))
    }

    @Test func successNamingAnotherBoxCarriesIt() async {
        let json = #"{"ok": true, "next": \#(P.json(P.oneOff))}"#
        #expect(await decide(reply(json)) == .sent(next: P.oneOff))
    }

    @Test func everyRefusalIsShownInTheDashboardsWords() async {
        for message in [
            "permission prompt changed or gone — re-check the pane",
            "pane w1:p1 not found — likely closed",
            "no allow/deny/allow-always option on this prompt",
            "press did not land — re-check the pane",
        ] {
            let json = #"{"ok": false, "error": "\#(message)"}"#
            #expect(await decide(reply(json)) == .failed(message))
        }
    }

    @Test func aMissingPaneIdIsARealRefusalNotAMissingEndpoint() async {
        #expect(await decide(reply(#"{"ok": false, "error": "missing paneId"}"#, status: 400)) == .failed("missing paneId"))
    }

    @Test func aDashboardWithoutTheEndpointIsUnsupportedWhateverItSays() async {
        #expect(await decide(reply(#"{"error": "not found"}"#, status: 404)) == .unsupported("not found"))
        #expect(await decide(reply("Method Not Allowed", status: 405)) == .unsupported("HTTP 405"))
        #expect(await decide(reply(#"{"ok": true}"#, status: 404)) == .unsupported("HTTP 404"))
    }

    @Test func anUnreadableReplyIsAFailureNeverASuccess() async {
        let result = await decide(reply("<html>oops</html>"))
        guard case .failed = result else {
            Issue.record("expected a failure, got \(result)")
            return
        }
    }

    @Test func aReplyWithoutAnOkFlagIsAFailure() async {
        let result = await decide(reply("{}"))
        guard case .failed = result else {
            Issue.record("expected a failure, got \(result)")
            return
        }
    }

    @Test func anUnreachableDashboardIsAFailureInWords() async {
        #expect(await decide(ScriptedDashboardTransport { _ in .fail }) == .failed("Can't reach the status dashboard."))
    }

    @Test func aDecisionRequestNeverRetries() async {
        let transport = ScriptedDashboardTransport { _ in .fail }
        _ = await decide(transport)
        #expect(transport.requests.count == 1)
    }

    /// An edit box's detail carries the file and its diff rows joined by newlines, with leading spaces:
    /// the dashboard compares the whole string, so it must come back exactly.
    @Test func aMultiLineDetailIsEchoedExactlyIncludingItsNewlinesAndIndentation() throws {
        let edit = PermissionPrompt(
            tool: "Update",
            detail: ".claude/chief-mode\n 1  on 2026-09-15T04:21:16+00:00 84ac01f3-…\n 2 +\n\t3 -tab  \n… (5 more line(s) truncated)",
            title: "Do you want to make this edit to chief-mode?",
            options: [.init(index: 1, label: "Yes"), .init(index: 2, label: "Yes, and allow Claude to edit files in this project's .claude folder for this session"), .init(index: 3, label: "No")],
            cursorIndex: 1
        )
        let sent = try #require(JSONSerialization.jsonObject(with: Data(P.json(edit).utf8)) as? NSDictionary)
        let decoded = try #require(try JSONDecoder().decode(DashboardPermission.self, from: Data(P.json(edit).utf8)).prompt)
        let echoed = try #require(try body(of: endpoint.permissionRequest(paneId: "w1:p1", choice: .allowAlways, permission: decoded))["permission"] as? NSDictionary)
        #expect(echoed == sent)
        #expect((echoed["detail"] as? String) == edit.detail)
    }
}
