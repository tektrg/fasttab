import Foundation
import Testing
@testable import AgentBar

/// `OpenRouterJevClient` over a scripted transport: never a real network call.
struct OpenRouterJevClientTests {
    private let candidates = [
        RouteCandidate(agentID: "agent-1", summary: "Fixing the login bug"),
        RouteCandidate(agentID: "agent-2", summary: "Writing release notes"),
    ]

    private func makeClient(_ transport: FakeJevHTTPTransport) -> OpenRouterJevClient {
        OpenRouterJevClient(apiKey: "test-key", timeoutSeconds: 8, transport: transport)
    }

    private func requestBody(of transport: FakeJevHTTPTransport) throws -> [String: Any] {
        let request = try #require(transport.requests.first)
        let data = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func routeInstructions(of transport: FakeJevHTTPTransport) throws -> String {
        let body = try requestBody(of: transport)
        let questions = try #require(body["questions"] as? [String: Any])
        let route = try #require(questions["route"] as? [String: Any])
        return try #require(route["instructions"] as? String)
    }

    // MARK: - Request shape

    @Test func theRequestIsAPostToTheDecisionsEndpointWithTheKeyAndModel() async throws {
        let transport = FakeJevHTTPTransport(.body(Data(#"{"answers":{"route":{"choice":"agent-1"}}}"#.utf8)))
        _ = await makeClient(transport).route(text: "help me ship this", candidates: candidates)

        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url == OpenRouterJevClient.endpoint)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        #expect(request.timeoutInterval == 8)

        let body = try requestBody(of: transport)
        #expect(body["model"] as? String == "~typesafe/jev-latest")
        #expect(body["state"] as? String == "help me ship this")
        let questions = try #require(body["questions"] as? [String: Any])
        let route = try #require(questions["route"] as? [String: Any])
        #expect(route["type"] as? String == "choice")
        #expect(route["instructions"] as? String == "Pick the specific live session this message is for.")
        let criteria = try #require(route["criteria"] as? [String: String])
        #expect(criteria == ["agent-1": "Fixing the login bug", "agent-2": "Writing release notes"])
    }

    @Test func theDefaultModelCanBeOverridden() async throws {
        let transport = FakeJevHTTPTransport(.body(Data(#"{"answers":{"route":{"choice":"agent-1"}}}"#.utf8)))
        let client = OpenRouterJevClient(apiKey: "k", model: "~typesafe/jev-mini", timeoutSeconds: 8, transport: transport)
        _ = await client.route(text: "hi", candidates: candidates)
        #expect(try requestBody(of: transport)["model"] as? String == "~typesafe/jev-mini")
    }

    // MARK: - System prompt (RoutingSettings.systemPrompt), folded into the instructions

    @Test func withNoSystemPromptTheInstructionsAreExactlyTheBaseContract() async throws {
        let transport = FakeJevHTTPTransport(.body(Data(#"{"answers":{"route":{"choice":"agent-1"}}}"#.utf8)))
        _ = await makeClient(transport).route(text: "hi", candidates: candidates)
        #expect(try routeInstructions(of: transport) == "Pick the specific live session this message is for.")
    }

    @Test func aBlankSystemPromptIsDroppedRatherThanSentAsAnEmptySection() async throws {
        let transport = FakeJevHTTPTransport(.body(Data(#"{"answers":{"route":{"choice":"agent-1"}}}"#.utf8)))
        let client = OpenRouterJevClient(apiKey: "k", systemPrompt: "   \n  ", timeoutSeconds: 8, transport: transport)
        _ = await client.route(text: "hi", candidates: candidates)
        #expect(try routeInstructions(of: transport) == "Pick the specific live session this message is for.")
    }

    @Test func aCustomSystemPromptIsAppendedAfterTheBaseInstructionsClearlyDelimited() async throws {
        let transport = FakeJevHTTPTransport(.body(Data(#"{"answers":{"route":{"choice":"agent-1"}}}"#.utf8)))
        let client = OpenRouterJevClient(apiKey: "k", systemPrompt: "Prefer the fe agent for UI bugs.", timeoutSeconds: 8, transport: transport)
        _ = await client.route(text: "hi", candidates: candidates)
        let instructions = try routeInstructions(of: transport)
        // The base contract is always the prefix — a user's own guidance is additive, never a
        // replacement for or a prefix ahead of it.
        #expect(instructions.hasPrefix("Pick the specific live session this message is for."))
        #expect(instructions.contains("Prefer the fe agent for UI bugs."))
        #expect(instructions != "Pick the specific live session this message is for.")
    }

    // MARK: - Empty candidates: no network call

    @Test func emptyCandidatesReturnsNoneWithoutANetworkCall() async {
        let transport = FakeJevHTTPTransport(.body(Data()))
        let outcome = await makeClient(transport).route(text: "hi", candidates: [])
        #expect(outcome == .none)
        #expect(transport.callCount == 0)
    }

    // MARK: - Successful pick

    @Test func aKnownChoiceWithConfidenceIsPicked() async {
        let transport = FakeJevHTTPTransport(.body(Data(#"""
        {"answers":{"route":{"type":"choice","choice":"agent-2","confidence":0.83}},"usage":{"input_tokens":10,"output_tokens":2}}
        """#.utf8)))
        let outcome = await makeClient(transport).route(text: "release notes please", candidates: candidates)
        #expect(outcome == .picked(agentID: "agent-2", confidence: 0.83))
    }

    @Test func missingConfidenceReadsAsZeroNeverAsAGuess() async {
        let transport = FakeJevHTTPTransport(.body(Data(#"{"answers":{"route":{"choice":"agent-1"}}}"#.utf8)))
        let outcome = await makeClient(transport).route(text: "hi", candidates: candidates)
        #expect(outcome == .picked(agentID: "agent-1", confidence: 0.0))
    }

    // MARK: - Unknown choice

    @Test func aChoiceNotInTheCandidateListFails() async {
        let transport = FakeJevHTTPTransport(.body(Data(#"{"answers":{"route":{"choice":"agent-does-not-exist"}}}"#.utf8)))
        let outcome = await makeClient(transport).route(text: "hi", candidates: candidates)
        #expect(outcome == .failed("Jev picked an unknown agent"))
    }

    @Test func anEmptyChoiceFails() async {
        let transport = FakeJevHTTPTransport(.body(Data(#"{"answers":{"route":{"choice":""}}}"#.utf8)))
        let outcome = await makeClient(transport).route(text: "hi", candidates: candidates)
        if case .failed = outcome {} else { Issue.record("expected .failed, got \(outcome)") }
    }

    @Test func aMissingRouteAnswerFails() async {
        let transport = FakeJevHTTPTransport(.body(Data(#"{"answers":{}}"#.utf8)))
        let outcome = await makeClient(transport).route(text: "hi", candidates: candidates)
        if case .failed = outcome {} else { Issue.record("expected .failed, got \(outcome)") }
    }

    // MARK: - Transport / HTTP failures

    @Test func aTimeoutFails() async {
        let transport = FakeJevHTTPTransport(.error(URLError(.timedOut)))
        let outcome = await makeClient(transport).route(text: "hi", candidates: candidates)
        #expect(outcome == .failed("Jev routing timed out."))
    }

    @Test func aConnectionFailureFails() async {
        let transport = FakeJevHTTPTransport(.error(FakeJevHTTPTransport.ScriptedError()))
        let outcome = await makeClient(transport).route(text: "hi", candidates: candidates)
        if case .failed = outcome {} else { Issue.record("expected .failed, got \(outcome)") }
    }

    @Test func malformedJsonFails() async {
        let transport = FakeJevHTTPTransport(.body(Data("not json at all".utf8)))
        let outcome = await makeClient(transport).route(text: "hi", candidates: candidates)
        #expect(outcome == .failed("Jev routing returned an unreadable reply."))
    }

    @Test func aNon2xxStatusFails() async {
        let transport = FakeJevHTTPTransport(.body(Data(#"{"error":"invalid_api_key"}"#.utf8), statusCode: 401))
        let outcome = await makeClient(transport).route(text: "hi", candidates: candidates)
        #expect(outcome == .failed("Jev routing failed (HTTP 401)."))
    }

    @Test func aRateLimitStatusFails() async {
        let transport = FakeJevHTTPTransport(.body(Data(), statusCode: 429))
        let outcome = await makeClient(transport).route(text: "hi", candidates: candidates)
        #expect(outcome == .failed("Jev routing failed (HTTP 429)."))
    }

    @Test func aServerErrorStatusFails() async {
        let transport = FakeJevHTTPTransport(.body(Data(), statusCode: 503))
        let outcome = await makeClient(transport).route(text: "hi", candidates: candidates)
        #expect(outcome == .failed("Jev routing failed (HTTP 503)."))
    }
}
