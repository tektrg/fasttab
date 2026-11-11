import Foundation
import IndieCommandBar

/// Keyboard selection over the selectable agent ids (headers and unfocusable
/// rows are already excluded by the caller). Pure.
enum AgentSelection {
    /// Moves `step` rows (+1 down, -1 up). Wraps at either end: the list is
    /// short and this is a switcher, so a lone press past the last row lands on
    /// the first instead of dead-ending. With nothing selected, down picks the
    /// first row and up the last.
    static func moved(from current: String?, by step: Int, in selectable: [String]) -> String? {
        guard !selectable.isEmpty else { return nil }
        if abs(step) == 1 {
            // ↑/↓: the shared shell's wrap rule (no search-field stop; nothing selected = before the first row).
            let index = current.flatMap { selectable.firstIndex(of: $0) } ?? -1
            let moved = CommandBarController.movedSelection(
                from: index, direction: step > 0 ? .forward : .backward,
                itemCount: selectable.count, includeSearchField: false
            )
            return selectable[moved.index]
        }
        guard let current, let index = selectable.firstIndex(of: current) else {
            return step >= 0 ? selectable.first : selectable.last
        }
        let count = selectable.count
        return selectable[((index + step) % count + count) % count]
    }

    /// After the list changed under the user (a refresh arrived): keep the
    /// selection if that agent is still selectable, else fall to the first row.
    static func reconciled(_ current: String?, in selectable: [String]) -> String? {
        if let current, selectable.contains(current) { return current }
        return selectable.first
    }

    /// Where the selection goes when `id` leaves its place (parked, finished):
    /// the row after it, else the one before, else nothing. Lets the user work
    /// down the list without re-aiming after each action.
    static func neighbour(of id: String, in selectable: [String]) -> String? {
        guard let index = selectable.firstIndex(of: id) else { return nil }
        if index + 1 < selectable.count { return selectable[index + 1] }
        return index > 0 ? selectable[index - 1] : nil
    }
}
