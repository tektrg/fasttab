import Foundation

/// Fast Tab's inputs to the shared close-on-leave rule (`CommandBarPointerLeaveMonitor`).
enum FastTabPointerLeaveGates {
    /// How far the cursor must clear the surface before it counts as "left" — stops sub-pixel
    /// jitter right at the edge from starting the close.
    static let outset: CGFloat = 6
    /// After a shortcut/menu-bar open the pointer may rest anywhere: leaving only counts after this.
    static let shortcutOpenGrace: TimeInterval = 1.0

    /// What holds the bar open whatever the pointer does: a floating card (it may sit away from the
    /// edge that opened it; click outside / Esc close it), a hidden bar, an open view builder or
    /// delete confirmation (work in progress), no panel yet, or a shortcut modifier held down (a
    /// keyboard cycle is in progress — ⌥ of ⌥Q; the pointer rests anywhere, usually outside).
    static func isHeld(
        isFloating: Bool, isVisible: Bool, editorHoldsBar: Bool, hasPanel: Bool, isShortcutModifierHeld: Bool = false
    ) -> Bool {
        isFloating || !isVisible || editorHoldsBar || !hasPanel || isShortcutModifierHeld
    }
}
