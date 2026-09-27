import Foundation

/// Outcome of asking the status backend to switch to an agent.
struct FocusResult: Equatable, Sendable {
    let succeeded: Bool
    /// Plain-English failure reason when `succeeded` is false.
    let errorMessage: String?

    static let success = FocusResult(succeeded: true, errorMessage: nil)
    static func failure(_ message: String) -> FocusResult {
        FocusResult(succeeded: false, errorMessage: message)
    }
}

/// Outcome of reading a pane's current screen (for the peek).
enum PaneScreenResult: Equatable, Sendable {
    case screen(lines: [String], readAt: Date)
    case failure(String)
}

/// Where AgentBar gets agent status from and how it acts on it. It acts only
/// on the user's explicit action: switching, Stop / Close (Done), and sending
/// the answer the user picked to an agent's open question. Today that is
/// the AptusFit chief dashboard (`DashboardStatusSource`); a standalone status
/// service can replace it without touching the UI.
protocol AgentStatusSource: Sendable {
    /// Every refresh, in order. Includes `.down` snapshots when the backend is
    /// unreachable or unhealthy. Single consumer.
    var updates: AsyncStream<StatusSnapshot> { get }

    /// Brings the agent's terminal tab to the front.
    func focus(paneId: String) async -> FocusResult

    /// Current screen text of a pane. Slow (~2.5s): call on demand, never poll.
    func paneScreen(paneId: String) async -> PaneScreenResult

    /// Sends the user's answer to the question open in the pane. `question` is the
    /// one the user was shown: the dashboard refuses when the pane no longer
    /// shows it. Never call twice for one decision: a slow reply may still have
    /// landed, and a repeat could answer the next question.
    func answer(paneId: String, choice: AnswerChoice, question: QuestionIdentity) async -> AnswerResult

    /// Sends the user's decision on the permission box open in the pane. `permission` is
    /// the box exactly as the pane reads now: the dashboard refuses (and presses nothing)
    /// unless the box in the pane still equals it. Never call twice for one decision.
    func permission(paneId: String, choice: PermissionChoice, permission: PermissionPrompt) async -> PermissionResult

    /// Picks row `index` (1-based) of the plan-approval box open in the pane. `text` goes only with the
    /// feedback row ("Tell Claude what to change"). `permission` is the box as the pane reads now, option
    /// labels included: the dashboard refuses unless the box it reads still equals it. Never call twice for one decision.
    func selectPlanOption(paneId: String, index: Int, text: String?, permission: PermissionPrompt) async -> PermissionResult

    /// Answers a status-only session's prompt held by the dashboard's hook bridge (`HookRequest`), by its id.
    /// No pane is read or typed into. Never call twice for one decision.
    func answerHookRequest(requestId: String, answer: HookAnswer) async -> HookAnswerOutcome

    /// Stops the agent or closes its pane (the dashboard's ladder). Destructive:
    /// call only for an explicit user press. `confirmed` is true only for the
    /// second press after `.needsConfirmation`.
    func perform(_ kind: SessionActionKind, rowId: String, confirmed: Bool) async -> SessionActionOutcome

    /// Types `text` (already one line, no leading "/") into the agent's input and submits it.
    /// `confirmed` is true only for the second press after `.needsConfirmation`. Never call
    /// twice for one message: a slow reply may still have landed.
    func sendMessage(rowId: String, text: String, confirmed: Bool) async -> MessageSendOutcome
}

extension AgentStatusSource {
    /// Sources that cannot message an agent refuse, in words.
    func sendMessage(rowId: String, text: String, confirmed: Bool) async -> MessageSendOutcome {
        .failed("This status source cannot send messages.")
    }

    /// Sources that cannot decide permission boxes refuse, in words.
    func permission(paneId: String, choice: PermissionChoice, permission: PermissionPrompt) async -> PermissionResult {
        .unsupported("This status source cannot approve or deny from here.")
    }

    func selectPlanOption(paneId: String, index: Int, text: String?, permission: PermissionPrompt) async -> PermissionResult {
        .unsupported("This status source cannot answer a plan from here.")
    }

    func answerHookRequest(requestId: String, answer: HookAnswer) async -> HookAnswerOutcome {
        .failed("This status source cannot answer Claude sessions outside herdr.")
    }
}
