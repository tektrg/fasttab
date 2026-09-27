import Foundation

/// The body of `POST /api/hook/permission/<requestId>/answer`: what the user decided on a hook request.
/// The dashboard builds Claude's decision from it (original tool input + `answers`, or the chosen
/// "always allow" suggestion). Answer texts are already sanitised the way the dashboard checks them:
/// control characters dropped, whitespace runs (line breaks too) one space, at most 500 characters.
struct HookAnswer: Equatable, Sendable {
    enum Behavior: String, Equatable, Sendable {
        case allow
        case deny
    }

    let behavior: Behavior
    /// Question text -> answer (a label, labels joined with ", ", or free text). Question requests only.
    let answers: [String: String]?
    /// Which of the request's `permission.suggestions` to apply for good. Allow only.
    let suggestionIndex: Int?
    /// Said to Claude with a denial.
    let message: String?

    static let denialMessage = "The user denied this from AgentBar."

    var jsonObject: [String: Any] {
        var body: [String: Any] = ["behavior": behavior.rawValue]
        if let answers { body["answers"] = answers }
        if let suggestionIndex { body["suggestionIndex"] = suggestionIndex }
        if let message { body["message"] = message }
        return body
    }

    // MARK: - Building

    /// One question answered on the single card. Nil when the choice names no option of it.
    static func answering(_ question: FormQuestion, with choice: AnswerChoice) -> HookAnswer? {
        let formChoice: FormChoice
        switch choice {
        case .text(let typed): formChoice = .other(typed)
        case .select(let numbers):
            // The card numbers options 1...n (`HookRequest.answerableQuestion`); the Other row is never selected.
            let positions = numbers.map { $0 - 1 }
            guard !positions.isEmpty, positions.allSatisfy(question.options.indices.contains) else { return nil }
            formChoice = .options(positions)
        }
        return answering([question], with: [formChoice])
    }

    /// Every question of a form answered at once. Nil unless each question has a sendable answer.
    static func answering(_ questions: [FormQuestion], with choices: [FormChoice]) -> HookAnswer? {
        guard !questions.isEmpty, questions.count == choices.count else { return nil }
        var answers: [String: String] = [:]
        for (question, choice) in zip(questions, choices) {
            if case .options(let positions) = choice, positions.isEmpty || !positions.allSatisfy(question.options.indices.contains) {
                return nil
            }
            guard let text = OtherAnswerText.sendable(RecordedFormAnswers.words(for: choice, question: question)) else { return nil }
            answers[question.question] = text
        }
        return HookAnswer(behavior: .allow, answers: answers, suggestionIndex: nil, message: nil)
    }

    /// A decision on a permission request.
    static func deciding(_ choice: PermissionChoice) -> HookAnswer {
        switch choice {
        case .deny: HookAnswer(behavior: .deny, answers: nil, suggestionIndex: nil, message: denialMessage)
        case .allowAlwaysSuggestion(let index): HookAnswer(behavior: .allow, answers: nil, suggestionIndex: index, message: nil)
        case .allow, .allowAlways: HookAnswer(behavior: .allow, answers: nil, suggestionIndex: nil, message: nil)
        }
    }
}

/// How the dashboard took a hook answer.
enum HookAnswerOutcome: Equatable, Sendable {
    case sent
    /// Refused (e.g. already answered in Claude) or unreachable, in the dashboard's own words when it gave any.
    /// Never retried.
    case failed(String)
}

/// `POST /api/hook/permission/<id>/answer` reply: `{"ok": true}` or an error (409 `{error}` when the
/// request is no longer pending, 404 when the dashboard does not know it).
enum DashboardHookAnswerResponse {
    static let goneMessage = "The dashboard no longer has this prompt waiting (answered in Claude, or the dashboard restarted)."

    private struct Reply: Decodable {
        let ok: Bool?
        let error: String?
    }

    static func outcome(body: Data, statusCode: Int) -> HookAnswerOutcome {
        let reply = try? JSONDecoder().decode(Reply.self, from: body)
        if (200..<300).contains(statusCode), reply?.ok != false { return .sent }
        if let error = reply?.error, !error.isEmpty { return .failed(error) }
        if statusCode == 404 { return .failed(goneMessage) }
        return .failed("The dashboard refused the answer (HTTP \(statusCode)).")
    }
}
