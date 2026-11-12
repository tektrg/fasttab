import AppKit
import Foundation
import Testing
import IndieCommandBar
@testable import FastTab

/// Characterization written before the shared preview slot (gap 4) landed in IndieCommandBar:
/// Fast Tab supplies no previews, so Space and Esc must keep doing exactly what they did.
@MainActor
struct FastTabSpacePreviewCharacterizationTests {
    typealias R = FastTabKeyRouting
    typealias Ctx = FastTabKeyRouting.Context

    private func route(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags = [], _ c: Ctx = Ctx()) -> R.Action {
        R.route(keyCode: keyCode, modifiers: modifiers, context: c, hooks: R.Hooks())
    }

    private func onRow(_ index: Int, _ row: R.SelectedRow) -> Ctx {
        var c = Ctx()
        c.selectedIndex = index
        c.selectedRow = row
        return c
    }

    @Test func spaceOnAHighlightedRowStillMovesTheSelection() {
        for row in [R.SelectedRow.liveTab, .stackSlot] {
            #expect(route(R.spaceKeyCode, [], onRow(2, row)) == .moveSelection(forward: true, via: .space))
            #expect(route(R.spaceKeyCode, [.shift], onRow(2, row)) == .moveSelection(forward: false, via: .space))
        }
    }

    @Test func spaceFromTheSearchFieldStillMovesTheSelection() {
        #expect(route(R.spaceKeyCode, [], onRow(-1, .liveTab)) == .moveSelection(forward: true, via: .space))
    }

    @Test func escStillClearsTheRowThenHidesTheBar() {
        #expect(route(R.escapeKeyCode, [], onRow(1, .liveTab)) == .clearSelection)
        #expect(route(R.escapeKeyCode, [], onRow(-1, .liveTab)) == .hideBar)
    }
}
