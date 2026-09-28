import Foundation

/// How the dashboard answered a message to an agent.
enum MessageSendOutcome: Equatable, Sendable {
    /// The text reached the agent's input. `queued`: it arrived mid-turn and waits its turn.
    case sent(queued: Bool)
    /// Nothing was sent: the agent is mid-turn, so the message would queue. `reason` is the server's words.
    case needsConfirmation(reason: String)
    /// Refused or unreachable, in words; nothing (or, for "NOT SUBMITTED", only unsent text) reached the agent.
    case failed(String)
    /// No reply in time: it may have gone through. Never retried on its own.
    case uncertain(String)

    static let textMayBeInInputBoxWords = "The message may be sitting typed in the agent's input box, not submitted. Clear or submit it in the terminal first: sending again would type it twice."
}

extension DashboardSessionActionResponse {
    /// The outcome a `/api/session/message` reply amounts to; nil when it says nothing usable.
    var messageOutcome: MessageSendOutcome? {
        if ok == true { return .sent(queued: state?.lowercased().contains("queued") == true) }
        if needsConfirm == true { return .needsConfirmation(reason: reason ?? "") }
        guard let error else { return nil }
        if Self.leavesTextInInputBox(error) { return .uncertain(MessageSendOutcome.textMayBeInInputBoxWords) }
        // Inbox route (`session_inbox.MAYBE_SENT`): the connection broke after bytes left, so the
        // message may already be in the session. `.failed` would let a headless send retry it twice.
        if error.lowercased().contains("may or may not have arrived") { return .uncertain(error) }
        return .failed(error)
    }

    /// The dashboard types the text, presses Return, then checks. When it says the text is stuck (or the sequence broke
    /// halfway) the typed text may still sit in the agent's input box, and it never clears it: sending again would type
    /// the message a second time after the first copy and submit both together.
    private static func leavesTextInInputBox(_ error: String) -> Bool {
        let lowered = error.lowercased()
        return lowered.hasPrefix("not submitted") || lowered.contains("mid-sequence")
    }
}
