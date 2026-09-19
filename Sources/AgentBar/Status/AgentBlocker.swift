import Foundation

/// Why an agent in Needs you is blocked on the user, when the dashboard says a
/// real question or permission box is open (not merely "finished").
enum AgentBlocker: Equatable, Sendable {
    /// A question the panel can answer.
    case question(AnswerableQuestion)
    /// A question the dashboard has only previewed so far: its screen sweep
    /// lags up to ~15s, so the options arrive shortly. Answer waits, disabled.
    /// Carries the previewed question when the dashboard named it.
    case questionLoading(QuestionIdentity?)
    /// A question whose shape AgentBar will not answer (options already ticked,
    /// an odd layout): terminal only.
    case questionNotAnswerable
    /// A permission box (or anything else blocking): terminal only.
    case permission
}
