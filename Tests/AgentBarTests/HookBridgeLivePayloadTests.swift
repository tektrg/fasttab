import Foundation
import Testing
@testable import AgentBar

/// Real `/api/state` payloads captured from a scratch dashboard while an isolated Claude CLI session sat on
/// a hook-bridge prompt (`Fixtures/hook-bridge-state-*.json`, trimmed to that session). They pin the contract
/// between the two halves: the dashboard keeps needsYou `kind: "blocked"` for both prompt kinds, so the
/// card must come from `hookRequest.kind`; and the answer body AgentBar builds is exactly what the dashboard
/// accepts (the same bodies were POSTed to that dashboard and Claude went on).
struct HookBridgeLivePayloadTests {
    static let endpoint = DashboardEndpoint(baseURL: URL(string: "http://127.0.0.1:4713")!)

    static func snapshot(_ fixture: String) throws -> StatusSnapshot {
        let url = try #require(Bundle.module.url(forResource: fixture, withExtension: "json", subdirectory: "Fixtures"))
        return try StatusSnapshotBuilder.snapshot(fromJSON: Data(contentsOf: url), fetchedAt: Date())
    }

    static func hookRow(_ fixture: String) throws -> AgentSnapshot {
        try #require(try snapshot(fixture).agents.first { $0.hookRequest != nil })
    }

    static func body(_ answer: HookAnswer, requestId: String) throws -> String {
        let request = try #require(endpoint.hookAnswerRequest(requestId: requestId, answer: answer))
        return String(decoding: try #require(request.httpBody), as: UTF8.self)
    }

    @Test func aRealBashPromptBecomesAReviewCardWithItsSuggestion() throws {
        let row = try Self.hookRow("hook-bridge-state-permission")
        #expect(row.section == .needsYou)
        #expect(row.paneId == nil)
        guard case .permissionReview(let prompt)? = row.blockedOnYou else {
            Issue.record("expected a Review blocker, got \(String(describing: row.blockedOnYou))")
            return
        }
        #expect(prompt.tool == "Bash")
        #expect(prompt.title == "Run a shell command")
        #expect(prompt.detail.hasPrefix("python3 -c \"print('hookqa-one')\""))
        #expect(prompt.choices == [.allow, .allowAlwaysSuggestion(0), .deny])
        #expect(prompt.option(for: .allowAlwaysSuggestion(0))?.label
            == "Always allow `Bash(python3 -c \"print('hookqa-one')\")` in this project")
    }

    @Test func theBashAnswerBodiesAreWhatTheDashboardTakes() throws {
        let id = try #require(try Self.hookRow("hook-bridge-state-permission").hookRequest?.requestId)
        #expect(try Self.body(.deciding(.allowAlwaysSuggestion(0)), requestId: id) == #"{"behavior":"allow","suggestionIndex":0}"#)
        #expect(try Self.body(.deciding(.allow), requestId: id) == #"{"behavior":"allow"}"#)
        #expect(try Self.body(.deciding(.deny), requestId: id)
            == #"{"behavior":"deny","message":"The user denied this from AgentBar."}"#)
    }

    @Test func aRealAskUserQuestionBecomesAnAnswerCard() throws {
        let row = try Self.hookRow("hook-bridge-state-question")
        #expect(row.section == .needsYou)
        guard case .question(let question)? = row.blockedOnYou else {
            Issue.record("expected an Answer blocker, got \(String(describing: row.blockedOnYou))")
            return
        }
        #expect(question.title == "Fruit")
        #expect(question.question == "Which fruit do you want?")
        #expect(question.options.map(\.label) == ["Apple", "Pear", HookRequest.otherOptionLabel])
        #expect(row.statusText == "Fruit: Which fruit do you want?")
    }

    @Test func theQuestionAnswerBodiesAreWhatTheDashboardTakes() throws {
        let request = try #require(try Self.hookRow("hook-bridge-state-question").hookRequest)
        let question = try #require(request.questions.first)
        let picked = try #require(HookAnswer.answering(question, with: .select([2])))
        #expect(try Self.body(picked, requestId: request.requestId)
            == #"{"answers":{"Which fruit do you want?":"Pear"},"behavior":"allow"}"#)
        let typed = try #require(HookAnswer.answering(question, with: .text("a kiwi\nplease")))
        #expect(try Self.body(typed, requestId: request.requestId)
            == #"{"answers":{"Which fruit do you want?":"a kiwi please"},"behavior":"allow"}"#)
    }
}
