import Foundation

/// The peek at one agent's pane screen: who it is about and what it shows.
struct PanePeek: Equatable {
    static let endedAgentMessage = "No live screen for an ended agent."
    static let blankScreenMessage = "The pane's screen is blank right now."
    static let noSourceMessage = "No status dashboard to read from."

    enum Content: Equatable {
        /// Waiting on the dashboard (the read takes a couple of seconds).
        case loading
        case screen(lines: [String], readAt: Date)
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
}
