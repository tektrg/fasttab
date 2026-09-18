import AppKit
import CommandBarKit

/// Turns hotkey presses and modifier changes into panel decisions: open, move
/// the selection either way, or commit on release. The kit's `CycleSession`
/// does the hold/release bookkeeping; this adds the AgentBar specifics
/// (backward steps, plain-open mode, opening the panel on the first press).
///
/// Behaviour:
/// - Press while the panel is closed: open it, first row selected, no cycling
///   yet. Releasing the modifier then leaves it open ("plain" mode).
/// - Press while it is open: move the selection (⇧ = backward). Releasing the
///   modifier after at least one move commits it. This is also true in plain
///   mode: the press means the modifier is down again, so releasing it is the
///   usual alt-tab "let go to switch".
/// - Release with nothing selectable, or without ever cycling: nothing happens.
@MainActor
final class AgentCycleController {
    struct Actions {
        var isPanelVisible: @MainActor () -> Bool
        var openPanel: @MainActor () -> Void
        /// Moves the selection by ±1; true when a row is now selected.
        var moveSelection: @MainActor (Int) -> Bool
        /// Switches to the selected row.
        var commitSelection: @MainActor () -> Void
    }

    private let session: CycleSession
    private let shortcutModifiers: NSEvent.ModifierFlags
    private let actions: Actions
    private var pendingStep = 1

    /// `shortcutModifiers` are the modifiers whose release commits (⌥ by default).
    init(shortcutModifiers: NSEvent.ModifierFlags, actions: Actions) {
        let masked = shortcutModifiers.intersection(.deviceIndependentFlagsMask)
        self.shortcutModifiers = masked
        self.actions = actions
        self.session = CycleSession(isShortcutModifierHeld: { flags in !flags.intersection(masked).isEmpty })
        session.onAdvance = { [unowned self] in actions.moveSelection(pendingStep) }
        session.onCommit = { actions.commitSelection() }
    }

    /// A shortcut press. `currentModifiers` is the live keyboard state.
    func hotkeyPressed(_ direction: CycleDirection, currentModifiers: NSEvent.ModifierFlags) {
        guard actions.isPanelVisible() else {
            actions.openPanel()
            session.reset()
            session.isModifierHeld = isShortcutModifierDown(in: currentModifiers)
            return
        }
        session.isModifierHeld = isShortcutModifierDown(in: currentModifiers)
        pendingStep = direction.step
        session.advance()
    }

    /// Feed the live keyboard state while the panel is visible; a release after
    /// cycling commits.
    func modifiersChanged(_ currentModifiers: NSEvent.ModifierFlags) {
        session.handleFlagsChanged(currentModifiers)
    }

    /// The panel closed by any route: forget the cycle so a stale one cannot commit.
    func panelClosed() {
        session.reset()
        session.isModifierHeld = false
    }

    private func isShortcutModifierDown(in flags: NSEvent.ModifierFlags) -> Bool {
        !flags.intersection(.deviceIndependentFlagsMask).intersection(shortcutModifiers).isEmpty
    }
}
