import AppKit
import Combine

/// Alt-tab style cycling: while the shortcut modifier is held, each extra press
/// of the hotkey advances the selection; releasing the modifier commits it.
///
/// The host owns one session. Its hotkey handler calls `advance()`, its
/// flags-changed monitor calls `handleFlagsChanged(_:)`, and its view supplies
/// `onAdvance` (move the selection) and `onCommit` (activate the selection).
@MainActor
public final class CycleSession: ObservableObject {
    /// True once the user has cycled onto an item; releasing the modifier then commits.
    @Published public private(set) var hasCycled = false
    /// True while any of the host's shortcut modifiers is held. The host may seed
    /// it directly when the bar opens (it has no flags-changed event to go on).
    @Published public var isModifierHeld = false

    /// Moves the selection forward; returns true when an item (not the search
    /// field) is now selected, i.e. a release should commit.
    public var onAdvance: (@MainActor @Sendable () -> Bool)?
    /// Activates the current selection.
    public var onCommit: (@MainActor @Sendable () -> Void)?

    private let isShortcutModifierHeld: @MainActor @Sendable (NSEvent.ModifierFlags) -> Bool

    /// - Parameter isShortcutModifierHeld: whether the given flags hold any of the
    ///   host's shortcut modifiers.
    public init(isShortcutModifierHeld: @escaping @MainActor @Sendable (NSEvent.ModifierFlags) -> Bool) {
        self.isShortcutModifierHeld = isShortcutModifierHeld
    }

    public func advance() {
        guard let onAdvance else { return }
        hasCycled = onAdvance()
    }

    /// Updates modifier tracking. Returns true when the release committed the cycled item.
    @discardableResult
    public func handleFlagsChanged(_ flags: NSEvent.ModifierFlags) -> Bool {
        let isHeld = isShortcutModifierHeld(flags.intersection(.deviceIndependentFlagsMask))
        // Only publish real changes: every flags event would otherwise redraw the host view.
        if isModifierHeld != isHeld { isModifierHeld = isHeld }
        guard !isHeld, hasCycled else { return false }
        onCommit?()
        hasCycled = false
        return true
    }

    public func reset() {
        hasCycled = false
    }
}
