/// Who drives the highlighted row (`AppState.selectedIndex`): the keyboard, or — once the mouse
/// has really moved inside the bar — the mouse, whose hovered row then becomes the selection that
/// Return, ⌘C and the arrows act on. A key press or shortcut tap hands control back.
///
/// "Really moved" comes from `CommandBarPointerTakeoverMonitor` (≥ 2pt inside the bar); SwiftUI
/// hover events alone also fire when a row slides under a resting pointer (the bar opening there,
/// the keyboard scrolling the list), and those never steal the selection.
struct FastTabPointerSelection: Equatable {
    private(set) var pointerHasControl = false
    /// The row under the pointer (`CommandBarDisplayItem.id`), if any.
    private(set) var hoveredRowID: String?

    /// A real pointer move inside the bar: the mouse takes control. Returns the row to select —
    /// the one under the pointer — only when control changes hands (later moves leave it to
    /// `rowHoverChanged`), and only if that row is still listed and not already selected.
    mutating func pointerMoved(selectedIndex: Int, indexOfRow: (String) -> Int?) -> Int? {
        guard !pointerHasControl else { return nil }
        pointerHasControl = true
        guard let hoveredRowID, let index = indexOfRow(hoveredRowID), index != selectedIndex else { return nil }
        return index
    }

    /// The pointer entered (`isHovering`) or left row `id` at `index`. Returns the row to select
    /// while the mouse has control. Leaving a row keeps it selected.
    mutating func rowHoverChanged(_ id: String, index: Int, isHovering: Bool, selectedIndex: Int) -> Int? {
        if isHovering {
            hoveredRowID = id
        } else if hoveredRowID == id {
            hoveredRowID = nil
        }
        guard isHovering, pointerHasControl, index != selectedIndex else { return nil }
        return index
    }

    /// A key press or a shortcut tap (keyboard cycle): the keyboard drives the highlight again.
    mutating func keyboardTookControl() {
        pointerHasControl = false
    }
}
