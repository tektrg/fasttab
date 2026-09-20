import Foundation

/// What the agent's transcript says a submitted AskUserQuestion form recorded: the answer text per question
/// (0-based position in the form). This is what the agent actually received, whoever pressed the keys.
struct RecordedFormAnswers: Equatable, Sendable {
    let answers: [Int: String]

    /// Does the recorded text say what the user's draft chose? Order is ignored for a multi-select; a label that is only
    /// the start of another ("Yes" / "Yes, and remember") never counts as a match. Spacing is ignored.
    static func draftMatches(_ choice: FormChoice, question: FormQuestion, recorded: String) -> Bool {
        switch choice {
        case .other(let text):
            return QuestionIdentity.comparable(text) == QuestionIdentity.comparable(recorded)
        case .options(let positions):
            var remaining = QuestionIdentity.comparable(recorded)
            let labels = positions.map { QuestionIdentity.comparable(question.options[$0].label) }.sorted { $0.count > $1.count }
            for label in labels {
                guard let range = remaining.range(of: label) else { return false }
                remaining.removeSubrange(range)
            }
            return remaining.allSatisfy { $0 == "," }   // only the list separators are left
        }
    }

    /// The draft in the user's words: the chosen labels, or the typed text.
    static func words(for choice: FormChoice, question: FormQuestion) -> String {
        switch choice {
        case .other(let text): text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .options(let positions): positions.map { question.options[$0].label }.joined(separator: ", ")
        }
    }
}

/// Finds the `tool_result` of an AskUserQuestion call in a transcript tail and reads the answers out of it. Real shape:
/// a user line whose `tool_result` text is `The user answered: "Q1"="A1", "Q2"="A2". Read the answers carefully…`, and
/// (same line) `toolUseResult.answers`, a map keyed by question text. Pure: bytes in, answers out.
enum AskUserQuestionResultExtractor {
    private static let toolResultMarker = Data("tool_result".utf8)
    private static let newline = UInt8(ascii: "\n")
    private static let answersEndMarker = ". Read the answers carefully"

    /// Nil unless the newest result for `toolUseId` records at least one answer for a question of `form`.
    /// A refusal ("the user doesn't want to proceed") records none.
    static func find(toolUseId: String, form: PendingQuestionForm, in tail: Data, chunkStartsAtFileStart: Bool) -> RecordedFormAnswers? {
        var lines = tail.split(separator: newline, omittingEmptySubsequences: true)
        if !chunkStartsAtFileStart, !lines.isEmpty { lines.removeFirst() }   // cut mid-line
        let idBytes = Data(toolUseId.utf8)
        for line in lines.reversed() {
            guard line.range(of: toolResultMarker) != nil, line.range(of: idBytes) != nil,
                  let entry = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let block = resultBlock(in: entry, toolUseId: toolUseId) else { continue }
            if block["is_error"] as? Bool == true { return nil }
            let fromMap = answersFromMap((entry["toolUseResult"] as? [String: Any])?["answers"] as? [String: Any], form: form)
            let fromText = resultText(block).map { answersFromText($0, form: form) } ?? [:]
            let best = fromText.count > fromMap.count ? fromText : fromMap
            return best.isEmpty ? nil : RecordedFormAnswers(answers: best)
        }
        return nil
    }

    private static func resultBlock(in entry: [String: Any], toolUseId: String) -> [String: Any]? {
        guard entry["type"] as? String == "user", let message = entry["message"] as? [String: Any],
              let blocks = message["content"] as? [[String: Any]] else { return nil }
        return blocks.first { $0["type"] as? String == "tool_result" && $0["tool_use_id"] as? String == toolUseId }
    }

    private static func resultText(_ block: [String: Any]) -> String? {
        if let text = block["content"] as? String { return text }
        let parts = (block["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }
        return parts.map { $0.joined(separator: "\n") }
    }

    /// Keys are question texts; a key that is not exactly one of the form's questions (a tab name) is ignored.
    private static func answersFromMap(_ map: [String: Any]?, form: PendingQuestionForm) -> [Int: String] {
        var answers: [Int: String] = [:]
        for (key, value) in map ?? [:] {
            guard let text = value as? String else { continue }
            let wanted = QuestionIdentity.comparable(key)
            if let index = form.questions.firstIndex(where: { QuestionIdentity.comparable($0.question) == wanted }) { answers[index] = text }
        }
        return answers
    }

    /// The form's own question texts are the anchors (`"<question>"="`): an answer can hold quotes and commas, so
    /// splitting on punctuation would cut it. Each answer runs to the start of the next anchor, or the closing sentence.
    private static func answersFromText(_ text: String, form: PendingQuestionForm) -> [Int: String] {
        let anchors: [(index: Int, range: Range<String.Index>)] = form.questions.enumerated().compactMap { index, question in
            text.range(of: "\"\(question.question)\"=\"").map { (index, $0) }
        }.sorted { $0.range.lowerBound < $1.range.lowerBound }
        let closing = text.range(of: answersEndMarker, options: .backwards)?.lowerBound ?? text.endIndex
        var answers: [Int: String] = [:]
        for (position, anchor) in anchors.enumerated() {
            let end = position + 1 < anchors.count ? anchors[position + 1].range.lowerBound : closing
            guard anchor.range.upperBound <= end else { continue }
            answers[anchor.index] = cleanedAnswer(String(text[anchor.range.upperBound..<end]))
        }
        return answers
    }

    /// `A", ` (before the next anchor) or `A"` (before the closing sentence) -> `A`.
    private static func cleanedAnswer(_ slice: String) -> String {
        var answer = slice.trimmingCharacters(in: .whitespacesAndNewlines)
        while answer.hasSuffix(",") { answer.removeLast() }
        answer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        if answer.hasSuffix("\"") { answer.removeLast() }
        return answer
    }
}
