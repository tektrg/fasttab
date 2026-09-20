import Foundation

/// Finds the AskUserQuestion call an agent is waiting on in the tail of its session
/// transcript. Pure: bytes in, finding out. The call is an assistant line with a
/// `tool_use` block named AskUserQuestion holding every question of the form; it is
/// pending until a later line carries a `tool_result` for the same `tool_use` id
/// (the answer, or a rejection). Only the newest such call counts.
enum AskUserQuestionExtractor {
    enum Finding: Equatable, Sendable {
        /// The newest call has no result yet.
        case pending(PendingQuestionForm)
        /// The newest call is already answered or was refused: no need to look further back.
        case settled
        /// No usable call in this chunk (a wider one may still have it).
        case notFound
    }

    private static let toolName = "AskUserQuestion"
    private static let assistantMarker = Data("\"assistant\"".utf8)
    private static let toolNameMarker = Data(toolName.utf8)
    private static let toolResultMarker = Data("tool_result".utf8)
    private static let newline = UInt8(ascii: "\n")

    static func find(in tail: Data, chunkStartsAtFileStart: Bool) -> Finding {
        var lines = tail.split(separator: newline, omittingEmptySubsequences: true)
        if !chunkStartsAtFileStart, !lines.isEmpty { lines.removeFirst() }   // cut mid-line
        for (position, line) in lines.enumerated().reversed() {
            guard line.range(of: assistantMarker) != nil, line.range(of: toolNameMarker) != nil,
                  let call = askUserQuestionBlock(inLine: line),
                  let id = call["id"] as? String else { continue }
            if hasResult(forToolUse: id, in: lines[(position + 1)...]) { return .settled }
            guard let form = form(id: id, input: call["input"] as? [String: Any]) else { return .notFound }
            return .pending(form)
        }
        return .notFound
    }

    /// The last AskUserQuestion `tool_use` block of a main-conversation assistant line.
    private static func askUserQuestionBlock(inLine line: Data) -> [String: Any]? {
        guard let entry = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              entry["type"] as? String == "assistant", entry["isSidechain"] as? Bool != true,
              let message = entry["message"] as? [String: Any],
              let blocks = message["content"] as? [[String: Any]] else { return nil }
        return blocks.last { $0["type"] as? String == "tool_use" && $0["name"] as? String == toolName }
    }

    /// A byte search, not a parse: result lines can be huge, and the id is unique.
    private static func hasResult(forToolUse id: String, in laterLines: ArraySlice<Data>) -> Bool {
        let idBytes = Data(id.utf8)
        return laterLines.contains { $0.range(of: toolResultMarker) != nil && $0.range(of: idBytes) != nil }
    }

    /// Nil when any question is unreadable: a form shown half right would answer the wrong thing.
    private static func form(id: String, input: [String: Any]?) -> PendingQuestionForm? {
        guard let rawQuestions = input?["questions"] as? [[String: Any]], !rawQuestions.isEmpty else { return nil }
        var questions: [FormQuestion] = []
        for raw in rawQuestions {
            guard let question = raw["question"] as? String,
                  !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let rawOptions = raw["options"] as? [[String: Any]], !rawOptions.isEmpty else { return nil }
            var options: [FormQuestion.Option] = []
            for rawOption in rawOptions {
                guard let label = rawOption["label"] as? String, !label.isEmpty else { return nil }
                options.append(.init(label: label, description: rawOption["description"] as? String ?? ""))
            }
            questions.append(FormQuestion(
                header: raw["header"] as? String ?? "", question: question,
                isMultiSelect: raw["multiSelect"] as? Bool ?? false, options: options
            ))
        }
        return PendingQuestionForm(toolUseId: id, questions: questions)
    }
}
