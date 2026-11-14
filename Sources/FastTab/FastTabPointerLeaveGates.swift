import Foundation

/// Fast Tab's inputs to the shared close-on-leave rule (`CommandBarPointerLeaveMonitor`).
enum FastTabPointerLeaveGates {
    /// How far the cursor must clear the surface before it counts as "left" — stops sub-pixel
    /// jitter right at the edge from starting the close.
    static let outset: CGFloat = 6
    /// After a shortcut open, leaving only counts after this (and after the pointer has been on the bar).
    static let shortcutOpenGrace: TimeInterval = 1.0

    /// What holds the bar open whatever the pointer does: a floating card (it may sit away from the
    /// edge that opened it; click outside / Esc close it), a hidden bar, an open view builder or
    /// delete confirmation (work in progress), or no panel yet. A held shortcut modifier (a keyboard
    /// cycle — ⌥ of ⌥Q) also holds it, through the shared rule's `isShortcutModifierHeld` hook.
    static func isHeld(isFloating: Bool, isVisible: Bool, editorHoldsBar: Bool, hasPanel: Bool) -> Bool {
        isFloating || !isVisible || editorHoldsBar || !hasPanel
    }

    /// Every open except a hover / edge reveal (shortcut, per-view shortcuts, menu bar, Dock,
    /// onboarding) leaves the pointer wherever it was — usually outside the bar — so it closes only
    /// after the pointer has been on the bar and left. A hover reveal opens under the pointer.
    static func requiresPointerVisit(isHoverReveal: Bool) -> Bool {
        !isHoverReveal
    }
}
