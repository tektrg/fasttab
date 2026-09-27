import Foundation

/// The hook-bridge side of the answer card: a status-only session's AskUserQuestion held by the dashboard
/// (`HookRequest`). No pane: the card shows the request's own questions (all of them at once when there are
/// several), and one `POST /api/hook/permission/<id>/answer` carries every answer. Never retried.
extension AnswerCardModel {
    /// A request with two or more questions opens straight on the form card.
    static func hookForm(_ request: HookRequest?) -> AnswerFormState? {
        guard let request, request.questions.count >= PendingQuestionForm.minimumQuestionCount else { return nil }
        return AnswerFormState(form: PendingQuestionForm(toolUseId: "hook:\(request.requestId)", questions: request.questions))
    }

    /// The single card's answer, as the dashboard takes it for a hook request.
    nonisolated static func sendHookAnswer(
        _ choice: AnswerChoice, to shown: AnswerableQuestion, of request: HookRequest, source: any AgentStatusSource
    ) async -> AnswerResult {
        guard let question = request.questions.first(where: { $0.question == shown.question }),
              let answer = HookAnswer.answering(question, with: choice) else {
            return .failed("AgentBar could not match your answer to the question. Nothing was sent.")
        }
        return await sendHook(answer, requestId: request.requestId, source: source)
    }

    nonisolated static func sendHook(_ answer: HookAnswer, requestId: String, source: any AgentStatusSource) async -> AnswerResult {
        switch await source.answerHookRequest(requestId: requestId, answer: answer) {
        case .sent: .sent(next: nil)
        case .failed(let message): .failed(message)
        }
    }

    /// Submit on a hook form: every answer in one request. The card closes at once; the row says
    /// "Sending answer…" until the dashboard replies; a failure goes to the footer notice, verbatim.
    func submitHookForm(_ request: HookRequest, card: AnswerCard, choices: [FormChoice], source: any AgentStatusSource) {
        guard let token = tracker.begin(agentID: card.agentID, at: now()) else { return }
        close()
        scheduleExpiry(agentID: card.agentID, token: token)
        let agentID = card.agentID
        let identity = card.state.question.identity
        let draft = card.state.draft
        let answer = HookAnswer.answering(request.questions, with: choices)
        Task { [weak self] in
            let result: AnswerResult = if let answer {
                await Self.sendHook(answer, requestId: request.requestId, source: source)
            } else {
                .failed("AgentBar could not match your answers to the questions. Nothing was sent.")
            }
            self?.finishSend(result, token: token, agentID: agentID, identity: identity, draft: draft)
        }
    }
}
