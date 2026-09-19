import Foundation
import Testing
@testable import AgentBar

/// Answering over the wire. Every test goes through a scripted transport:
/// nothing here can reach a real dashboard.
struct AnswerRequestTests {
    private let endpoint = DashboardEndpoint(baseURL: URL(string: "http://127.0.0.1:4799")!)
    private let identity = QuestionIdentity(title: "Fruit", question: "│ Which  fruit? │ (pick one)")

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

    // MARK: - Request shape (the dashboard's own UI sends exactly this)

    @Test func aSelectIsAPostWithSortedIndicesAndTheQuestionVerbatim() throws {
        let request = endpoint.answerRequest(paneId: "w1:p1", choice: .select([3, 1]), question: identity)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/answer")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let json = try body(of: request)
        #expect(json["paneId"] as? String == "w1:p1")
        let choice = try #require(json["choice"] as? [String: Any])
        #expect(choice["type"] as? String == "select")
        #expect(choice["indices"] as? [Int] == [1, 3])
        let question = try #require(json["question"] as? [String: String])
        #expect(question == ["title": "Fruit", "question": "│ Which  fruit? │ (pick one)"])
        #expect(Set(json.keys) == ["paneId", "choice", "question"])
    }

    @Test func aTextAnswerIsTypeTextAndValue() throws {
        let request = endpoint.answerRequest(paneId: "w1:p1", choice: .text("something else"), question: identity)
        let choice = try #require(try body(of: request)["choice"] as? [String: Any])
        #expect(choice["type"] as? String == "text")
        #expect(choice["value"] as? String == "something else")
        #expect(choice["indices"] == nil)
    }

    @Test func theRequestWaitsLongEnoughForTheDashboardsRetriesAndReReads() {
        let request = endpoint.answerRequest(paneId: "w1:p1", choice: .select([1]), question: identity)
        #expect(request.timeoutInterval >= 60)
    }

    // MARK: - Replies

    @Test func successWithNoNextQuestion() async {
        let result = await makeSource(reply(#"{"ok": true, "next": null}"#)).answer(paneId: "w1:p1", choice: .select([1]), question: identity)
        #expect(result == .sent(next: nil))
    }

    @Test func successWithTheNextQuestionOfAMultiQuestionForm() async throws {
        let next = AnswerFixtures.questionJSON(title: "Colour", question: "Which colour?")
        let result = await makeSource(reply(#"{"ok": true, "next": \#(next)}"#)).answer(paneId: "w1:p1", choice: .select([1]), question: identity)
        guard case .sent(let question?) = result else {
            Issue.record("expected a next question, got \(result)")
            return
        }
        #expect(question.identity == QuestionIdentity(title: "Colour", question: "Which colour?"))
    }

    @Test func aNextQuestionWeCannotAnswerStillCountsAsAnswered() async {
        let result = await makeSource(reply(#"{"ok": true, "next": {"title": "T"}}"#)).answer(paneId: "w1:p1", choice: .select([1]), question: identity)
        #expect(result == .sent(next: nil))
    }

    @Test func aRefusalCarriesTheDashboardsWordsVerbatim() async {
        let result = await makeSource(reply(#"{"ok": false, "error": "question changed or gone — re-check the pane"}"#))
            .answer(paneId: "w1:p1", choice: .select([1]), question: identity)
        #expect(result == .failed("question changed or gone — re-check the pane"))
    }

    @Test func aRefusalWithNoReasonStillSaysItWasRefused() async {
        let result = await makeSource(reply(#"{"ok": false}"#)).answer(paneId: "w1:p1", choice: .select([1]), question: identity)
        #expect(result == .failed("The dashboard refused the answer."))
    }

    @Test func aMissingPaneIdIs400WithTheReasonAndStillReadsAsAFailure() async {
        let result = await makeSource(reply(#"{"ok": false, "error": "missing paneId"}"#, status: 400))
            .answer(paneId: "", choice: .select([1]), question: identity)
        #expect(result == .failed("missing paneId"))
    }

    @Test func anUnreadableReplyIsAFailureNeverASuccess() async {
        for junk in ["<html>oops</html>", "{}", "[]", ""] {
            let result = await makeSource(reply(junk)).answer(paneId: "w1:p1", choice: .select([1]), question: identity)
            guard case .failed = result else {
                Issue.record("\(junk) must not read as sent, got \(result)")
                continue
            }
        }
    }

    @Test func anUnreachableDashboardIsAFailure() async {
        let source = makeSource(ScriptedDashboardTransport { _ in .fail })
        #expect(await source.answer(paneId: "w1:p1", choice: .select([1]), question: identity) == .failed("Can't reach the status dashboard."))
    }

    @Test func aTimeoutWarnsThatTheAnswerMayHaveGoneThrough() async {
        struct TimeoutTransport: DashboardTransport {
            func response(for request: URLRequest) async throws -> (body: Data, statusCode: Int) { throw URLError(.timedOut) }
            func stream(for request: URLRequest) -> AsyncThrowingStream<Data, Error> { AsyncThrowingStream { $0.finish() } }
        }
        let result = await DashboardStatusSource(endpoint: endpoint, transport: TimeoutTransport())
            .answer(paneId: "w1:p1", choice: .select([1]), question: identity)
        guard case .failed(let message) = result else {
            Issue.record("expected a failure, got \(result)")
            return
        }
        #expect(message.contains("may have gone through"))
    }

    @Test func oneAnswerIsExactlyOneRequest() async {
        let transport = reply(#"{"ok": false, "error": "answer may not have landed — re-check the pane"}"#)
        _ = await makeSource(transport).answer(paneId: "w1:p1", choice: .select([1]), question: identity)
        #expect(transport.requests.count == 1)
    }
}
