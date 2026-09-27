import Foundation
import Testing
@testable import AgentBar

/// A waiting Claude Desktop / CLI session whose prompt the hook bridge does not hold: the dashboard's
/// `transcriptQuestion` (read from the transcript) is shown on the row, but never makes it answerable.
struct TranscriptQuestionFallbackTests {
    typealias S = StatusOnlyFixtures
    typealias H = HookFixtures

    static let transcriptQuestion = #"{"header": "Live refresh", "question": "Build the push server?", "questionCount": 1}"#

    static func needsYou(transcriptQuestion: String?, hookRequest: String? = nil) -> String {
        """
        {"kind": "blocked", "paneId": null, "detail": "Input needed", "agentSession": "\(S.desktopSession)",
         "source": "claude-desktop", "sinceSec": 12, "hookRequest": \(hookRequest ?? "null"),
         "transcriptQuestion": \(transcriptQuestion ?? "null")}
        """
    }

    static func mapped(transcriptQuestion: String?, hookRequest: String? = nil) throws -> AgentSnapshot? {
        try S.snapshot(
            agents: [S.desktopRow()],
            needsYou: [needsYou(transcriptQuestion: transcriptQuestion, hookRequest: hookRequest)]
        ).agents.first
    }

    @Test func theTranscriptQuestionIsShownOnTheRow() throws {
        let row = try #require(try Self.mapped(transcriptQuestion: Self.transcriptQuestion))
        #expect(row.section == .needsYou)
        #expect(row.statusText == "Live refresh: Build the push server?")
        #expect(row.promptExcerpt == "Build the push server?")
    }

    @Test func itIsDisplayOnlyNoAnswerButton() throws {
        let row = try #require(try Self.mapped(transcriptQuestion: Self.transcriptQuestion))
        #expect(row.blocker == nil)
        #expect(row.hookRequest == nil)
        #expect(RowButtons.available(for: row).map(\.button) == [.park])
    }

    @Test func aHookRequestWinsOverTheTranscriptQuestion() throws {
        let row = try #require(try Self.mapped(transcriptQuestion: Self.transcriptQuestion, hookRequest: H.questionRequest))
        #expect(row.hookRequest?.requestId == "req_q1")
        #expect(row.statusText == "Fruit: Which fruit?")
    }

    @Test func withNeitherTheRowStaysGeneric() throws {
        let row = try #require(try Self.mapped(transcriptQuestion: nil))
        #expect(row.statusText == "Input needed")
        #expect(row.blocker == nil)
    }

    @Test func aMalformedTranscriptQuestionIsIgnored() throws {
        let row = try #require(try Self.mapped(transcriptQuestion: #"{"header": 7, "question": ["x"]}"#))
        #expect(row.statusText == "Input needed")
    }
}
