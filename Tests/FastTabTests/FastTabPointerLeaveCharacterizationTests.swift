import Foundation
import IndieCommandBar
import Testing
@testable import FastTab

/// Pins Fast Tab's close-on-leave behaviour from before it moved onto the shared
/// `CommandBarPointerLeaveMonitor`: same holds, same 6pt edge, same 1 s shortcut grace,
/// no grace after a hover open, open menus ignored, empty search only.
struct FastTabPointerLeaveCharacterizationTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 2000)

    @Test func holds() {
        #expect(!FastTabPointerLeaveGates.isHeld(isFloating: false, isVisible: true, editorHoldsBar: false, hasPanel: true))
        #expect(FastTabPointerLeaveGates.isHeld(isFloating: true, isVisible: true, editorHoldsBar: false, hasPanel: true))
        #expect(FastTabPointerLeaveGates.isHeld(isFloating: false, isVisible: false, editorHoldsBar: false, hasPanel: true))
        #expect(FastTabPointerLeaveGates.isHeld(isFloating: false, isVisible: true, editorHoldsBar: true, hasPanel: true))
        #expect(FastTabPointerLeaveGates.isHeld(isFloating: false, isVisible: true, editorHoldsBar: false, hasPanel: false))
        #expect(FastTabPointerLeaveGates.outset == 6)
        #expect(FastTabPointerLeaveGates.shortcutOpenGrace == 1.0)
    }

    @Test func onlyAnEmptySearchCloses_menusIgnored() {
        #expect(!CommandBarPointerLeaveClose.mayClose(isSearchEmpty: false, isHeld: false, isMenuOpen: false))
        // Fast Tab passes holdsWhileMenuOpen: false, so the menu gate is always false.
        #expect(CommandBarPointerLeaveClose.mayClose(isSearchEmpty: true, isHeld: false, isMenuOpen: false))
    }

    @Test func hoverOpenClosesAfterTheDwell_shortcutOpenWaitsOneSecond() {
        var hover = CommandBarPointerLeaveClose(openedAt: t0, openGrace: 0)
        #expect(hover.evaluate(mayClose: true, isPointerOutside: true, lastTypingDate: nil, now: t0) == .schedule(0.35))

        var shortcut = CommandBarPointerLeaveClose(openedAt: t0, openGrace: 0)
        shortcut.delayArming(until: t0.addingTimeInterval(FastTabPointerLeaveGates.shortcutOpenGrace))
        #expect(shortcut.evaluate(mayClose: true, isPointerOutside: true, lastTypingDate: nil, now: t0.addingTimeInterval(0.99)) == .keep)
        #expect(shortcut.evaluate(mayClose: true, isPointerOutside: true, lastTypingDate: nil, now: t0.addingTimeInterval(1)) == .schedule(0.35))
    }
}
