import Foundation

/// How a message reaches an agent. A herdr pane gets the text typed into its terminal; a Claude
/// Desktop / plain CLI session (a status-only row, no pane) gets it through its own peer inbox —
/// the dashboard's `session_inbox.py` — where it arrives as a message from another agent: queued
/// while the agent works, never able to approve a permission or answer a question, and a slash
/// command there is just text (so none is ever sent that way).
enum MessageRoute: Equatable, Sendable {
    case pane(paneId: String)
    case inbox

    static let inboxCaption = "Arrives as an agent message — can't approve permissions."
    static let inboxSlashCommandHint = "Slash commands don't reach this session: it gets the text as a message from another agent."

    /// The route for `agent` right now, nil when it cannot take a message at all.
    init?(agent: AgentSnapshot) {
        if let paneId = agent.paneId, !paneId.isEmpty {
            self = .pane(paneId: paneId)
        } else if agent.messagesViaInbox {
            self = .inbox
        } else {
            return nil
        }
    }

    /// `/compact` and `/clear` work only when typed into a real terminal.
    var allowsQuickCommands: Bool { self != .inbox }

    /// What the card and the Message button's tooltip say about the route; nil for a pane.
    var caption: String? { self == .inbox ? Self.inboxCaption : nil }
}
