import Foundation

/// The peek at one agent's pane screen: who it is about and what it shows. A status-only row
/// (Claude Desktop / CLI outside herdr, `AgentHost`) has no pane: its peek is the latest message
/// from the session transcript instead.
struct PanePeek: Equatable {
    static let endedAgentMessage = "No live screen for an ended agent."
    static let noLatestMessage = "No pane to read, and no recent message in this session's transcript on this Mac."
    static let blankScreenMessage = "The pane's screen is blank right now."
    static let noSourceMessage = "No status dashboard to read from."

    enum Content: Equatable {
        /// Waiting on the dashboard (the read takes a couple of seconds).
        case loading
        case screen(lines: [String], readAt: Date)
        /// A status-only row: its transcript is being read.
        case loadingLatestMessage
        /// A status-only row: the agent's latest message (markdown).
        case latestMessage(String)
        /// Plain-English reason there is nothing to show.
        case unavailable(String)
    }

    let agentID: String
    let label: String
    let projectName: String?
    var content: Content

    /// The dashboard's answer, cleaned for display.
    static func content(from result: PaneScreenResult) -> Content {
        switch result {
        case .failure(let reason):
            return .unavailable(reason)
        case .screen(let rawLines, let readAt):
            let lines = PaneScreenText.cleaned(rawLines)
            return lines.isEmpty ? .unavailable(blankScreenMessage) : .screen(lines: lines, readAt: readAt)
        }
    }

    static func content(fromLatestMessage message: String?) -> Content {
        guard let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .unavailable(noLatestMessage)
        }
        return .latestMessage(message)
    }
}
