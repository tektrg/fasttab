import AppKit
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

    /// Owner report 2026-11-14: the bar closed mid-cycle while ⌥ (of ⌥Q) was still held —
    /// the pointer rests outside the bar for keyboard users. A held shortcut modifier holds it.
    @Test func aHeldShortcutModifierHoldsTheBar() {
        #expect(FastTabPointerLeaveGates.isHeld(
            isFloating: false, isVisible: true, editorHoldsBar: false, hasPanel: true, isShortcutModifierHeld: true
        ))
        #expect(!FastTabPointerLeaveGates.isHeld(
            isFloating: false, isVisible: true, editorHoldsBar: false, hasPanel: true, isShortcutModifierHeld: false
        ))
        // Held modifier → the shared rule never schedules a close, even after the grace.
        var rule = CommandBarPointerLeaveClose(openedAt: t0, openGrace: 0)
        let held = FastTabPointerLeaveGates.isHeld(
            isFloating: false, isVisible: true, editorHoldsBar: false, hasPanel: true, isShortcutModifierHeld: true
        )
        let mayClose = CommandBarPointerLeaveClose.mayClose(isSearchEmpty: true, isHeld: held, isMenuOpen: false)
        #expect(rule.evaluate(mayClose: mayClose, isPointerOutside: true, lastTypingDate: t0, now: t0.addingTimeInterval(5)) == .cancel)
    }

    /// The live check reads the configured shortcut's modifiers: ⌥ for ⌥Q, ⌃ for ⌃Tab.
    @MainActor @Test func liveModifierCheckMatchesTheConfiguredShortcut() {
        let defaults = UserDefaults(suiteName: "FastTabPointerLeaveHeld-\(UUID().uuidString)")!
        let store = ShortcutStore(defaults: defaults)
        store.update(keyCode: 12, modifiers: .option, keyName: "Q")
        #expect(store.isAnyShortcutModifierHeld(in: [.option]))
        #expect(store.isAnyShortcutModifierHeld(in: [.option, .shift]))
        #expect(!store.isAnyShortcutModifierHeld(in: []))
        #expect(!store.isAnyShortcutModifierHeld(in: [.shift]))
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
