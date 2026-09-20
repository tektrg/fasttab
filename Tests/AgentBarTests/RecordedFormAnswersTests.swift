import Foundation
import Testing
@testable import AgentBar

/// What the session transcript says a submitted AskUserQuestion form recorded. The result line is shaped like the
/// real ones (`Fixtures/ask-user-question-3-questions.jsonl` is the call; real results: a `tool_result` whose text is
/// `The user answered: "Q"="A", …. Read the answers carefully…`, plus a `toolUseResult.answers` map keyed by question text).
enum RecordedAnswersFixtures {
    static let form = FormFixtures.form()
    static let toolUseId = FormFixtures.realToolUseId

    private static func json(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    /// The result line: `answers` are (question text, answer) in order.
    static func resultLine(
        answers: [(String, String)], toolUseId: String = toolUseId, includeText: Bool = true, includeMap: Bool = true, mapKeyedByHeader: Bool = false
    ) -> String {
        let pairs = answers.map { "\"\($0.0)\"=\"\($0.1)\"" }.joined(separator: ", ")
        var entry: [String: Any] = ["type": "user", "message": ["role": "user", "content": [[
            "type": "tool_result", "tool_use_id": toolUseId,
            "content": includeText ? "The user answered: \(pairs). Read the answers carefully — they may request clarification, changes, or that you not proceed — and follow what they actually say." : "ok"
        ]]]]
        if includeMap {
            var map: [String: String] = [:]
            for (index, pair) in answers.enumerated() { map[mapKeyedByHeader ? form.questions[index].header : pair.0] = pair.1 }
            entry["toolUseResult"] = ["answers": map]
        }
        return json(entry)
    }

    static func rejectionLine(toolUseId: String = toolUseId) -> String {
        json(["type": "user", "message": ["role": "user", "content": [[
            "type": "tool_result", "tool_use_id": toolUseId, "is_error": true,
            "content": "The user doesn't want to proceed with this tool use."
        ]]]])
    }

    static var questionTexts: [String] { form.questions.map(\.question) }
    static func answers(_ picked: [String]) -> [(String, String)] { Array(zip(questionTexts, picked)) }
}

struct AskUserQuestionResultExtractorTests {
    typealias R = RecordedAnswersFixtures

    private func find(_ lines: [String], form: PendingQuestionForm = R.form) -> RecordedFormAnswers? {
        AskUserQuestionResultExtractor.find(toolUseId: R.toolUseId, form: form, in: TranscriptFixtures.jsonl(lines), chunkStartsAtFileStart: true)
    }

    private let picked = ["Just clear it (Recommended)", "Done returns, Parked stays", "No, panel only for now"]

    @Test func readsEveryRecordedAnswerFromTheStructuredMap() {
        let found = find([TranscriptFixtures.assistantText("hi"), R.resultLine(answers: R.answers(picked), includeText: false)])
        #expect(found?.answers == [0: picked[0], 1: picked[1], 2: picked[2]])
    }

    @Test func readsThemFromTheTextWhenThereIsNoMap() {
        let found = find([R.resultLine(answers: R.answers(picked), includeMap: false)])
        #expect(found?.answers == [0: picked[0], 1: picked[1], 2: picked[2]])
    }

    @Test func aTypedAnswerWithQuotesAndCommasSurvivesTheTextRoute() {
        let typed = "say \"hello\", then, \"stop\""
        let found = find([R.resultLine(answers: R.answers([picked[0], typed, picked[2]]), includeMap: false)])
        #expect(found?.answers[1] == typed)
        #expect(found?.answers[0] == picked[0] && found?.answers[2] == picked[2])
    }

    @Test func aMapKeyedByTheTabNameIsIgnoredAndTheTextIsUsed() {
        let found = find([R.resultLine(answers: R.answers(picked), mapKeyedByHeader: true)])
        #expect(found?.answers == [0: picked[0], 1: picked[1], 2: picked[2]])
    }

    @Test func aResultForAnotherCallIsNotThisForms() {
        #expect(find([R.resultLine(answers: R.answers(picked), toolUseId: "toolu_other")]) == nil)
    }

    @Test func aRejectionOrNoResultTellsNothing() {
        #expect(find([R.rejectionLine()]) == nil)
        #expect(find([TranscriptFixtures.assistantText("still waiting")]) == nil)
    }

    @Test func aResultThatNamesNoQuestionOfTheFormTellsNothing() {
        #expect(find([R.resultLine(answers: [("Something else?", "x")])]) == nil)
    }

    @Test func theReaderFindsItInAFileFarLargerThanTheFirstWindow() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentBarRecorded-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("p")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bulk = Array(repeating: TranscriptFixtures.userToolResult(String(repeating: "y", count: 10_000)), count: 60)
        try TranscriptFixtures.jsonl([FormFixtures.realCallLine] + bulk + [R.resultLine(answers: R.answers(picked))] + bulk)
            .write(to: folder.appendingPathComponent("s-1.jsonl"))
        let reader = SessionTranscriptReader(projectsRoot: root)
        #expect(reader.recordedAnswers(forSession: "s-1", form: R.form)?.answers[2] == picked[2])
        #expect(reader.recordedAnswers(forSession: "missing", form: R.form) == nil)
    }
}

struct RecordedAnswerComparisonTests {
    private let question = FormFixtures.form(multiSelect: [1]).questions[1]

    @Test func aSingleChoiceMatchesItsOwnLabelOnly() {
        let single = FormFixtures.form().questions[0]
        #expect(RecordedFormAnswers.draftMatches(.options([1]), question: single, recorded: "Close the worker too"))
        #expect(!RecordedFormAnswers.draftMatches(.options([1]), question: single, recorded: "Just clear it (Recommended)"))
    }

    @Test func aMultiSelectMatchesInAnyOrderButNotWithExtrasOrMissing() {
        #expect(RecordedFormAnswers.draftMatches(.options([0, 1]), question: question, recorded: "Back to Needs you (Recommended), Done returns, Parked stays"))
        #expect(RecordedFormAnswers.draftMatches(.options([0, 1]), question: question, recorded: "Done returns, Parked stays, Back to Needs you (Recommended)"))
        #expect(!RecordedFormAnswers.draftMatches(.options([0]), question: question, recorded: "Back to Needs you (Recommended), Done returns, Parked stays"))
        #expect(!RecordedFormAnswers.draftMatches(.options([0, 1]), question: question, recorded: "Back to Needs you (Recommended)"))
    }

    @Test func aTypedAnswerMatchesItsText() {
        #expect(RecordedFormAnswers.draftMatches(.other("my  own\nanswer"), question: question, recorded: "my own answer"))
        #expect(!RecordedFormAnswers.draftMatches(.other("my own answer"), question: question, recorded: "Back to Needs you (Recommended)"))
    }

    @Test func theDraftInWordsNamesLabelsOrTheTypedText() {
        #expect(RecordedFormAnswers.words(for: .options([0, 1]), question: question) == "Back to Needs you (Recommended), Done returns, Parked stays")
        #expect(RecordedFormAnswers.words(for: .other("typed"), question: question) == "typed")
    }
}
