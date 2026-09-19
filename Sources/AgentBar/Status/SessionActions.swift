import Foundation

/// The two destructive steps AgentBar asks the dashboard to perform, on the
/// user's explicit click: Stop ends the agent but leaves its terminal pane
/// open; Close then closes that pane's tab.
enum SessionActionKind: String, Equatable, Sendable {
    case stop
    case close

    /// For "Couldn't stop: ..." messages.
    var verb: String { rawValue }
}

/// How the dashboard answered a stop/close request.
enum SessionActionOutcome: Equatable, Sendable {
    case succeeded
    /// Nothing was done: the row has something at stake and the user must
    /// press again to confirm. `reason` is the server's words for the stake.
    case needsConfirmation(reason: String)
    /// Refused or unreachable; plain-English reason.
    case failed(String)
}
