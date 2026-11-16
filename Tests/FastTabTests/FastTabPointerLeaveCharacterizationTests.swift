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
    /// the pointer rests outside the bar for keyboard users. A held shortcut modifier holds it,
    /// now through the shared rule's modifier hook (Fast Tab's own gate no longer knows about keys).
    @MainActor @Test func aHeldShortcutModifierHoldsTheBarThroughTheSharedHook() {
        let defaults = UserDefaults(suiteName: "FastTabPointerLeaveHook-\(UUID().uuidString)")!
        let store = ShortcutStore(defaults: defaults)
        store.update(keyCode: 12, modifiers: .option, keyName: "Q")
        let notHeldByFastTab = FastTabPointerLeaveGates.isHeld(isFloating: false, isVisible: true, editorHoldsBar: false, hasPanel: true)
        #expect(!notHeldByFastTab)

        let held = CommandBarPointerLeaveClose.mayClose(
            isSearchEmpty: true, isHeld: notHeldByFastTab, isMenuOpen: false,
            isShortcutModifierHeld: store.isAnyShortcutModifierHeld(in: [.option, .shift])
        )
        var rule = CommandBarPointerLeaveClose(openedAt: t0, openGrace: 0)
        #expect(rule.evaluate(mayClose: held, isPointerOutside: true, lastTypingDate: t0, now: t0.addingTimeInterval(5)) == .cancel)

        // Letting go re-checks: the close is scheduled again.
        let released = CommandBarPointerLeaveClose.mayClose(
            isSearchEmpty: true, isHeld: notHeldByFastTab, isMenuOpen: false,
            isShortcutModifierHeld: store.isAnyShortcutModifierHeld(in: [])
        )
        #expect(rule.evaluate(mayClose: released, isPointerOutside: true, lastTypingDate: nil, now: t0.addingTimeInterval(6)) == .schedule(0.35))
    }

    /// Keyboard opens (shortcut, per-view shortcuts, menu bar, Dock, onboarding) leave the pointer
    /// wherever it was, so the bar closes only after the pointer has been on it and left. A hover /
    /// edge reveal opens under the pointer and keeps closing as soon as it leaves.
    @Test func onlyNonHoverOpensRequireAPointerVisit() {
        #expect(FastTabPointerLeaveGates.requiresPointerVisit(isHoverReveal: false))
        #expect(!FastTabPointerLeaveGates.requiresPointerVisit(isHoverReveal: true))

        var keyboard = CommandBarPointerLeaveClose(
            openedAt: t0, openGrace: 0, requiresPointerVisit: FastTabPointerLeaveGates.requiresPointerVisit(isHoverReveal: false)
        )
        keyboard.delayArming(until: t0.addingTimeInterval(FastTabPointerLeaveGates.shortcutOpenGrace))
        // ↑/↓ browsing with the pointer resting outside: never closes.
        #expect(keyboard.evaluate(mayClose: true, isPointerOutside: true, lastTypingDate: t0.addingTimeInterval(1), now: t0.addingTimeInterval(3)) == .cancel)
        // Pointer crosses the bar, then leaves: closes as a hover open would.
        _ = keyboard.evaluate(mayClose: true, isPointerOutside: false, lastTypingDate: nil, now: t0.addingTimeInterval(4))
        #expect(keyboard.evaluate(mayClose: true, isPointerOutside: true, lastTypingDate: nil, now: t0.addingTimeInterval(5)) == .schedule(0.35))
    }

    /// The mouse taking over mid-cycle (a real move inside the bar) drops the release-to-open.
    @MainActor @Test func pointerTakeoverCancelsTheKeyboardCycle() {
        let defaults = UserDefaults(suiteName: "FastTabPointerTakeover-\(UUID().uuidString)")!
        let store = ShortcutStore(defaults: defaults)
        store.update(keyCode: 12, modifiers: .option, keyName: "Q")
        let commits = CommitCounter()
        let session = AppState.makeCycleSession(store: store)
        session.onAdvance = { _ in true }
        session.onCommit = { commits.count += 1 }
        session.handleFlagsChanged(.option)
        session.advance()
        session.pointerTookOver()
        session.handleFlagsChanged([])
        #expect(commits.count == 0)
        // Tapping the shortcut again takes the keyboard back.
        session.handleFlagsChanged(.option)
        session.advance()
        session.handleFlagsChanged([])
        #expect(commits.count == 1)
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

@MainActor
private final class CommitCounter {
    var count = 0
}
