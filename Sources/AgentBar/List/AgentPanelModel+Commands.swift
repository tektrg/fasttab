import Foundation
import IndieCommandBar

/// Slash-command rows (gap 11, user 2026-11-12): typing "/" at the start of the search box shows
/// the matching commands (shared `CommandBarCommandRows` over `AgentBarCommands.all`) in place of
/// the agent list. ↑/↓ move the highlight, Return or a click runs it. Exact text + Return works
/// as before. Not while Tab-tagged, in New worker mode, in the view editor, or with a card open.
extension AgentPanelModel {
    var commandRows: [CommandBarCommand] {
        guard taggedAgentID == nil, newWorker == nil, pages.editor == nil, !isCardOpen, routingState == nil else { return [] }
        return CommandBarCommandRows.matching(query, in: AgentBarCommands.all)
    }

    /// The highlighted command row, clamped to what is shown.
    var highlightedCommand: CommandBarCommand? {
        let rows = commandRows
        guard !rows.isEmpty else { return nil }
        return rows[min(max(0, commandHighlightIndex), rows.count - 1)]
    }

    /// ↑/↓ while command rows show (wraps, like the agent list). False when none show.
    func moveCommandHighlight(by step: Int) -> Bool {
        let count = commandRows.count
        guard count > 0 else { return false }
        let current = min(max(0, commandHighlightIndex), count - 1)
        commandHighlightIndex = ((current + step) % count + count) % count
        return true
    }

    func highlightCommand(id: String) {
        guard let index = commandRows.firstIndex(where: { $0.id == id }) else { return }
        commandHighlightIndex = index
    }

    /// Return while command rows show: runs the highlighted one.
    func runHighlightedCommandRow() -> Bool {
        guard let command = highlightedCommand else { return false }
        run(command)
        return true
    }

    /// Runs a command exactly as typing its text + Return does.
    func run(_ command: CommandBarCommand) {
        query = command.trigger
        if command == AgentBarCommands.newWorker {
            _ = enterNewWorkerIfCommand()
        } else if command == AgentBarCommands.newView {
            _ = beginNewViewIfCommand()
        }
    }
}
