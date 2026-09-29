import Foundation

/// How a message reaches an agent. A herdr pane gets the text typed into its terminal; a Claude
/// Desktop / plain CLI session (a status-only row, no pane) gets it through its own peer inbox —
/// the dashboard's `session_inbox.py` — where it arrives as a message from another agent: queued
/// while the agent works, never able to approve a permission or answer a question, and a slash
/// command there is just text (so none is ever sent that way). An OpenCode or Codex pane
/// (`toolPane`) also takes the text as a plain prompt, but neither tool knows Claude's
/// `/compact` / `/clear`, and a leading `/` or `!` is a command in their input box.
enum MessageRoute: Equatable, Sendable {
    case pane(paneId: String)
    case toolPane(paneId: String, tool: String)
    case inbox

    static let inboxCaption = "Arrives as an agent message — can't approve permissions."
    static let inboxSlashCommandHint = "Slash commands don't reach this session: it gets the text as a message from another agent."
    static let toolPaneCaption = "Sent as a normal prompt, like typing it yourself."
    static let toolPaneCommandHint = "Messages starting with / or ! aren't sent from here. Type it in the terminal."

    /// The route for `agent` right now, nil when it cannot take a message at all.
    init?(agent: AgentSnapshot) {
        if let paneId = agent.paneId, !paneId.isEmpty {
            if let tool = agent.messageTool {
                self = .toolPane(paneId: paneId, tool: tool)
            } else {
                self = .pane(paneId: paneId)
            }
        } else if agent.messagesViaInbox {
            self = .inbox
        } else {
            return nil
        }
    }

    /// `/compact` and `/clear` work only when typed into a real terminal.
    var allowsQuickCommands: Bool {
        if case .pane = self { return true }
        return false
    }

    /// A leading `!` runs a shell command in an OpenCode / Codex input box.
    var refusesShellPrefix: Bool {
        if case .toolPane = self { return true }
        return false
    }

    /// The hint under the field for a refused leading `/` or `!`.
    var commandHint: String {
        switch self {
        case .inbox: Self.inboxSlashCommandHint
        case .toolPane: Self.toolPaneCommandHint
        case .pane: MessageDraftValidator.slashCommandHint
        }
    }

    /// What the card and the Message button's tooltip say about the route; nil for a Claude pane.
    var caption: String? {
        switch self {
        case .inbox: Self.inboxCaption
        case .toolPane: Self.toolPaneCaption
        case .pane: nil
        }
    }
}
