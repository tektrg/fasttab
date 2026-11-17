import Testing
@testable import FastTab

/// Owner intent (2026-11-14): "when mouse moves in the bar, it should take control, stop any key
/// behavior" — once the mouse has really moved, the highlighted row follows it (the same selection
/// Return / ⌘C / arrows use); a key press or shortcut tap hands control back. A row that merely
/// sits under a resting pointer (bar opened there, list scrolled by the keyboard) never steals it.
struct FastTabPointerSelectionTests {
    private let rows = ["a", "b", "c", "d"]
    private func index(of id: String) -> Int? { rows.firstIndex(of: id) }

    @Test func aRowUnderARestingPointerAtOpenIsNotSelected() {
        var selection = FastTabPointerSelection()
        #expect(selection.rowHoverChanged("c", index: 2, isHovering: true, selectedIndex: -1) == nil)
        #expect(!selection.pointerHasControl)
    }

    @Test func aRealMoveSelectsTheRowUnderThePointer() {
        var selection = FastTabPointerSelection()
        _ = selection.rowHoverChanged("c", index: 2, isHovering: true, selectedIndex: 0)
        #expect(selection.pointerMoved(selectedIndex: 0, indexOfRow: index) == 2)
        #expect(selection.pointerHasControl)
    }

    @Test func onceInControlHoveringAnotherRowSelectsIt() {
        var selection = FastTabPointerSelection()
        _ = selection.pointerMoved(selectedIndex: -1, indexOfRow: index)
        #expect(selection.rowHoverChanged("b", index: 1, isHovering: true, selectedIndex: -1) == 1)
        // Enter of the next row can arrive before the exit of the last one.
        #expect(selection.rowHoverChanged("c", index: 2, isHovering: true, selectedIndex: 1) == 2)
        #expect(selection.rowHoverChanged("b", index: 1, isHovering: false, selectedIndex: 2) == nil)
        #expect(selection.hoveredRowID == "c")
    }

    @Test func leavingRowsKeepsTheSelection() {
        var selection = FastTabPointerSelection()
        _ = selection.pointerMoved(selectedIndex: -1, indexOfRow: index)
        _ = selection.rowHoverChanged("b", index: 1, isHovering: true, selectedIndex: -1)
        #expect(selection.rowHoverChanged("b", index: 1, isHovering: false, selectedIndex: 1) == nil)
        // Moving over the search box / footer: nothing under the pointer, selection stays.
        #expect(selection.pointerMoved(selectedIndex: 1, indexOfRow: index) == nil)
    }

    @Test func theAlreadySelectedRowIsNotReselected() {
        var selection = FastTabPointerSelection()
        _ = selection.rowHoverChanged("b", index: 1, isHovering: true, selectedIndex: 1)
        #expect(selection.pointerMoved(selectedIndex: 1, indexOfRow: index) == nil)
        #expect(selection.rowHoverChanged("b", index: 1, isHovering: true, selectedIndex: 1) == nil)
    }

    /// Later moves while the mouse already has control leave selection to the hover events (no
    /// list lookup per mouse move).
    @Test func onlyTakingControlLooksTheRowUp() {
        var selection = FastTabPointerSelection()
        _ = selection.rowHoverChanged("b", index: 1, isHovering: true, selectedIndex: -1)
        var lookups = 0
        _ = selection.pointerMoved(selectedIndex: -1) { lookups += 1; return self.index(of: $0) }
        _ = selection.pointerMoved(selectedIndex: 1) { lookups += 1; return self.index(of: $0) }
        #expect(lookups == 1)
    }

    @Test func theKeyboardTakesControlBack() {
        var selection = FastTabPointerSelection()
        _ = selection.pointerMoved(selectedIndex: -1, indexOfRow: index)
        _ = selection.rowHoverChanged("b", index: 1, isHovering: true, selectedIndex: -1)
        selection.keyboardTookControl()
        #expect(!selection.pointerHasControl)
        // ↓ moved to "c" and the list scrolled "d" under the resting pointer: ignored.
        #expect(selection.rowHoverChanged("d", index: 3, isHovering: true, selectedIndex: 2) == nil)
        // The next real move hands it back to the row under the pointer.
        #expect(selection.pointerMoved(selectedIndex: 2, indexOfRow: index) == 3)
    }

    /// A row from a page that is gone (swiped to Stack, search changed) is not selected by index.
    @Test func aRowNoLongerListedIsNotSelected() {
        var selection = FastTabPointerSelection()
        _ = selection.rowHoverChanged("gone", index: 7, isHovering: true, selectedIndex: -1)
        #expect(selection.pointerMoved(selectedIndex: -1, indexOfRow: index) == nil)
    }
}
