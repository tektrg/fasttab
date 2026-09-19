import Foundation

/// What the dashboard says about one action on one row (its `actions.stop` /
/// `actions.close`). The server decides; AgentBar only renders it.
struct ActionAvailability: Equatable, Sendable {
    let isEnabled: Bool
    /// The first press will be answered "confirm first" (something is at stake).
    let needsConfirm: Bool
    /// Why the action is refused, or what is at stake, in the server's words.
    let reason: String?

    /// No information from the dashboard: leave the button usable. Safe, because
    /// the server re-checks every request and answers "confirm first" or a refusal.
    static let unknown = ActionAvailability(isEnabled: true, needsConfirm: false, reason: nil)
    static let unavailable = ActionAvailability(isEnabled: false, needsConfirm: false, reason: nil)
}

/// Stop and Close availability for a row (the two actions AgentBar performs).
struct AgentActions: Equatable, Sendable {
    let stop: ActionAvailability
    let close: ActionAvailability

    static let unknown = AgentActions(stop: .unknown, close: .unknown)
    /// Rows the dashboard offers nothing on (ended sessions whose pane is gone).
    static let none = AgentActions(stop: .unavailable, close: .unavailable)

    func availability(of kind: SessionActionKind) -> ActionAvailability {
        switch kind {
        case .stop: stop
        case .close: close
        }
    }
}
