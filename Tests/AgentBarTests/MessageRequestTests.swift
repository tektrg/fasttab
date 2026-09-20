import Foundation
import Testing
@testable import AgentBar

/// Messages over the wire. Every test goes through a scripted transport: nothing here can reach a real dashboard.
struct MessageRequestTests {
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

    @Test func aMessageIsAPostAsThePoActorWithTheTextAndNoConfirm() throws {
        let request = endpoint.messageRequest(rowId: "row-1", text: "please continue", confirmed: false)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/session/message")
        #expect(request.timeoutInterval == DashboardEndpoint.messageTimeoutSeconds)
        #expect(DashboardEndpoint.messageTimeoutSeconds >= 60)
        let json = try body(of: request)
        #expect(json["rowId"] as? String == "row-1")
        #expect(json["actor"] as? String == "po")
        #expect(json["text"] as? String == "please continue")
        #expect(json["confirm"] == nil)
        #expect(Set(json.keys) == ["rowId", "actor", "text"])
    }

    @Test func confirmIsSentOnlyOnTheConfirmedPress() throws {
        let request = endpoint.messageRequest(rowId: "row-1", text: "hi", confirmed: true)
        #expect(try body(of: request)["confirm"] as? Bool == true)
    }

    @Test func aSentReplyIsSent() async {
        let outcome = await makeSource(reply(#"{"ok": true, "state": "message sent", "reason": ""}"#))
            .sendMessage(rowId: "r", text: "hi", confirmed: false)
        #expect(outcome == .sent(queued: false))
    }

    @Test func aQueuedReplyIsQueued() async {
        let outcome = await makeSource(reply(#"{"ok": true, "state": "queued", "reason": "mid-turn"}"#))
            .sendMessage(rowId: "r", text: "hi", confirmed: true)
        #expect(outcome == .sent(queued: true))
    }

    @Test func needsConfirmMeansNothingWasSent() async {
        let outcome = await makeSource(reply(#"{"ok": false, "needsConfirm": true, "reason": "agent is mid-turn — the message queues"}"#))
            .sendMessage(rowId: "r", text: "hi", confirmed: false)
        #expect(outcome == .needsConfirmation(reason: "agent is mid-turn — the message queues"))
    }

    @Test func aRefusalCarriesTheServersWordsVerbatim() async {
        let outcome = await makeSource(reply(#"{"ok": false, "error": "refused: a permission prompt is open on that pane"}"#))
            .sendMessage(rowId: "r", text: "hi", confirmed: false)
        #expect(outcome == .failed("refused: a permission prompt is open on that pane"))
    }

    @Test func aReplyWithNoUsableAnswerIsAFailureNotASuccess() async {
        let outcome = await makeSource(reply("{}")).sendMessage(rowId: "r", text: "hi", confirmed: false)
        guard case .failed = outcome else {
            Issue.record("expected a failure, got \(outcome)")
            return
        }
    }

    @Test func aTimeoutSaysItMayHaveGoneThrough() async {
        let transport = ThrowingTransport(URLError(.timedOut))
        let outcome = await DashboardStatusSource(endpoint: endpoint, transport: transport)
            .sendMessage(rowId: "r", text: "hi", confirmed: false)
        guard case .uncertain(let words) = outcome else {
            Issue.record("expected uncertain, got \(outcome)")
            return
        }
        #expect(words.contains("may have gone through"))
        #expect(transport.callCount == 1)   // never retried
    }

    @Test func anUnreachableDashboardMeansNothingWasSent() async {
        let transport = ThrowingTransport(URLError(.cannotConnectToHost))
        let outcome = await DashboardStatusSource(endpoint: endpoint, transport: transport)
            .sendMessage(rowId: "r", text: "hi", confirmed: false)
        guard case .failed(let words) = outcome else {
            Issue.record("expected failed, got \(outcome)")
            return
        }
        #expect(words.contains("Nothing was sent"))
    }

    private final class ThrowingTransport: DashboardTransport, @unchecked Sendable {
        private let error: Error
        private let lock = NSLock()
        private var calls = 0
        init(_ error: Error) { self.error = error }
        var callCount: Int { lock.withLock { calls } }
        func response(for request: URLRequest) async throws -> (body: Data, statusCode: Int) {
            lock.withLock { calls += 1 }
            throw error
        }
        func stream(for request: URLRequest) -> AsyncThrowingStream<Data, Error> {
            AsyncThrowingStream { $0.finish(throwing: error) }
        }
    }
}
