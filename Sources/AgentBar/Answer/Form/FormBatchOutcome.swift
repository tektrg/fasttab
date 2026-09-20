import Foundation

/// What became of one question of a form during the batch send.
enum FormQuestionOutcome: Equatable, Sendable {
    /// Not reached yet.
    case waiting
    case sending
    /// The dashboard took the answer.
    case landed
    /// Not sent by choice: the terminal had already moved past it (answered there meanwhile).
    case skipped(String)
    /// The dashboard refused it (its words); the terminal was left as it was, or the answer may not have landed.
    case refused(String)
    /// Never attempted, because an earlier step stopped the batch.
    case notSent(String)
    /// The form was submitted and the transcript recorded `answer` for this question. `chose` is what the user's
    /// draft said instead, only when that differs: the terminal recorded something the user did not pick.
    case recorded(answer: String, chose: String?)
}

/// How a batch send ended.
struct FormBatchResult: Equatable, Sendable {
    let outcomes: [FormQuestionOutcome]
    /// Nil when every question was handled and the dashboard pressed Submit; else why it stopped.
    let stopReason: String?
    /// A question the dashboard saw open after the last one (nothing is expected).
    let finalNext: AnswerableQuestion?
    /// Every question the terminal showed during the batch: the answered ones, as the dashboard reads them.
    let seenIdentities: [QuestionIdentity]

    var isComplete: Bool { stopReason == nil }
}

/// The words for a batch that stopped or skipped something. Written for someone who cannot see the log:
/// which questions landed, which did not, and that nothing is sent twice.
enum FormBatchReport {
    static func summary(_ result: FormBatchResult, form: PendingQuestionForm) -> String {
        if let recorded = recordedSummary(result, form: form) { return recorded }
        var parts: [String] = []
        if let stopReason = result.stopReason { parts.append("Stopped: \(stopReason)") }
        let landed = numbers(of: result.outcomes) { $0 == .landed }
        if !landed.isEmpty { parts.append("Sent: \(names(landed, in: form)).") }
        for (index, outcome) in result.outcomes.enumerated() {
            let name = name(of: index, in: form)
            switch outcome {
            case .skipped(let reason): parts.append("Skipped \(name): \(reason)")
            case .refused(let message): parts.append("Not sent \(name): \(message)")
            case .waiting, .sending, .landed, .notSent, .recorded: break
            }
        }
        let unsent = numbers(of: result.outcomes) { if case .notSent = $0 { return true } else { return false } }
        if !unsent.isEmpty { parts.append("Not attempted: \(names(unsent, in: form)).") }
        if !result.isComplete { parts.append("Nothing was resent. Finish the rest in the terminal.") }
        return parts.joined(separator: " ")
    }

    /// The form is done and the agent's own record says what it received; anything that differs from the draft is called out.
    private static func recordedSummary(_ result: FormBatchResult, form: PendingQuestionForm) -> String? {
        var recorded: [(index: Int, answer: String, chose: String?)] = []
        for (index, outcome) in result.outcomes.enumerated() {
            if case .recorded(let answer, let chose) = outcome { recorded.append((index, answer, chose)) }
        }
        guard !recorded.isEmpty else { return nil }
        let list = recorded.map { "\(name(of: $0.index, in: form)) → \($0.answer)" }.joined(separator: ", ")
        var parts = ["The form was submitted. Recorded answers: \(list)."]
        for entry in recorded {
            guard let chose = entry.chose else { continue }
            parts.append("\(name(of: entry.index, in: form).capitalizedFirst): You chose \"\(chose)\" but the terminal recorded \"\(entry.answer)\" — check it.")
        }
        return parts.joined(separator: " ")
    }

    static func name(of index: Int, in form: PendingQuestionForm) -> String {
        let header = form.questions[index].header
        return header.isEmpty ? "question \(index + 1)" : "question \(index + 1) (\(header))"
    }

    private static func names(_ indices: [Int], in form: PendingQuestionForm) -> String {
        indices.map { name(of: $0, in: form) }.joined(separator: ", ")
    }

    private static func numbers(of outcomes: [FormQuestionOutcome], where matches: (FormQuestionOutcome) -> Bool) -> [Int] {
        outcomes.indices.filter { matches(outcomes[$0]) }
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
