import AppKit
import IndieCommandBar

/// The bar's keyDown decision table, kept pure so tests can pin it
/// (`FastTabKeyRoutingTests`). Fast Tab's own keys (view builder, ⌘1…9,
/// ⌘P/⌘W, ⌘S/⌘D, Stack reorder, Backspace, aliases, scope dropdown) get first
/// refusal; the rest goes to IndieCommandBar's `CommandBarKeyRouter`.
/// `ContentView.setupLocalMonitor` builds a `Context`, asks `route`, and
/// performs the returned `Action`.
enum FastTabKeyRouting {
    static let spaceKeyCode: UInt16 = 49
    static let returnKeyCode: UInt16 = 36
    static let deleteKeyCode: UInt16 = 51
    static let tabKeyCode: UInt16 = 48
    static let escapeKeyCode: UInt16 = 53
    static let leftArrowKeyCode: UInt16 = 123
    static let rightArrowKeyCode: UInt16 = 124
    static let upArrowKeyCode: UInt16 = 126
    static let downArrowKeyCode: UInt16 = 125
    static let pKeyCode: UInt16 = 35
    static let wKeyCode: UInt16 = 13
    /// ANSI number-row key codes → digit, for ⌘1…⌘9 view switching.
    static let digitKeyCodes: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]

    /// What the highlighted row is, as far as key routing cares.
    enum SelectedRow: Equatable {
        case none
        case stackSlot
        case liveTab
        case otherResult
        case other
    }

    struct Context {
        var isVisible = true
        var selectedIndex = -1
        var selectedRow: SelectedRow = .none
        var searchTextIsEmpty = true
        var isAliasActive = false
        /// The typed text names an alias this key (Tab/Space) may commit.
        var aliasCommittableByKey = false
        var hasScopeChips = false
        var isScopeDropdownVisible = false
        var isChipFocused = false
        var isStackActive = false
        var stackPinnedCount = 0
        /// Global shortcuts whose tap cycles the open bar (the summon shortcut, plus the
        /// Recents/Stack one while that view is showing): with ⇧ added they cycle back.
        var cycleShortcuts: [CycleShortcut] = []
        /// The search field has selected text: ⌘C copies that text, not the row.
        var hasTextSelection = false
    }

    struct CycleShortcut: Equatable {
        var keyCode: UInt16
        var modifiers: NSEvent.ModifierFlags
    }

    /// Side-effecting checks the decision depends on. Each returns whether it
    /// handled the key; routing stops at the first that does.
    struct Hooks {
        var customViewEditor: () -> CustomViewEditorKeyRoute = { .notInvolved }
        var selectNumberedView: (Int) -> Bool = { _ in false }
        var listShortcut: (UInt16) -> Bool = { _ in false }
        var scopeDropdownEnter: () -> Bool = { false }
    }

    enum Action: Equatable {
        /// Deliver the event untouched.
        case passThrough
        /// A hook already handled it; swallow the event.
        case consumed
        case togglePinStackSlot
        case togglePinTab
        case closeStackSlot
        case removeTab
        case reorderStack(up: Bool)
        case exitAliasMode
        case backspaceIntoChips
        case commitAlias
        case dismissScopeDropdown
        case unfocusChip
        case moveScopeSuggestion(by: Int)
        case moveSelection(forward: Bool, via: LastInteractionKey)
        /// ⇧ + a cycling shortcut while its modifiers are held: one row back.
        case cycleBackward
        case keyboardSwipe(CommandBarSwipeEdge)
        case activateSelection
        /// Esc with a row highlighted: back to the search field.
        case clearSelection
        /// Esc on the search field: hide the bar.
        case hideBar
        /// ⌘C on a row (shared `CommandBarShellCommand.copy`): run its copy action (the URL).
        case copySelection
        /// ⌘, (shared `CommandBarShellCommand.openSettings`): open Settings.
        case openSettings
    }

    /// `characters` = the event's `charactersIgnoringModifiers` (⌘C / ⌘, follow the keyboard layout).
    static func route(
        keyCode: UInt16, characters: String = "", modifiers: NSEvent.ModifierFlags, context c: Context, hooks: Hooks = Hooks()
    ) -> Action {
        guard c.isVisible else { return .passThrough }
        let userModifiers = modifiers.intersection(.deviceIndependentFlagsMask)
            .intersection([.command, .option, .control, .shift])
        let noModifiers = userModifiers.isEmpty
        let commandOnly = userModifiers == [.command]

        // The inline view builder owns the keyboard while it's up.
        switch hooks.customViewEditor() {
        case .consume: return .consumed
        case .passThrough: return .passThrough
        case .notInvolved: break
        }

        // ⇧ + the summon shortcut: cycle back (shared `CommandBarKeyRouter.isBackwardCycle`).
        let press = CommandBarKeyPress(keyCode: keyCode, flags: modifiers)
        if c.cycleShortcuts.contains(where: {
            CommandBarKeyRouter.isBackwardCycle(press, summonKeyCode: $0.keyCode, summonModifiers: CommandBarModifiers($0.modifiers))
        }) {
            return .cycleBackward
        }

        // Shell keys every command bar shares: ⌘C copies the highlighted row, ⌘, opens Settings.
        switch CommandBarKeyRouter.shellCommand(
            characters: characters, modifiers: CommandBarModifiers(modifiers), hasTextSelection: c.hasTextSelection
        ) {
        case .openSettings: return .openSettings
        case .copy:
            switch c.selectedRow {
            case .stackSlot, .liveTab, .otherResult: return .copySelection
            case .none, .other: break
            }
        case nil: break
        }

        // ⌘1…⌘9 view switching.
        if commandOnly, let number = digitKeyCodes[keyCode], hooks.selectNumberedView(number) {
            return .consumed
        }

        // ⌘P: toggle pin on the selected stack slot or live tab.
        if commandOnly, keyCode == pKeyCode {
            switch c.selectedRow {
            case .stackSlot: return .togglePinStackSlot
            case .liveTab: return .togglePinTab
            default: break
            }
        }

        // ⌘W: close the selected stack slot or live tab.
        if commandOnly, keyCode == wKeyCode {
            switch c.selectedRow {
            case .stackSlot: return .closeStackSlot
            case .liveTab: return .removeTab
            default: break
            }
        }

        // ⌘S / ⌘D: list bridges (Read later / Move to saved links).
        if commandOnly, hooks.listShortcut(keyCode) {
            return .consumed
        }

        // ⌥↑/⌥↓: reorder pinned Stack rows (sent-link rows below never move).
        if userModifiers == [.option], c.isStackActive, c.searchTextIsEmpty {
            let index = c.selectedIndex
            if keyCode == upArrowKeyCode, index > 0, index < c.stackPinnedCount {
                return .reorderStack(up: true)
            }
            if keyCode == downArrowKeyCode, index >= 0, index < c.stackPinnedCount - 1 {
                return .reorderStack(up: false)
            }
        }

        // Backspace at empty input: alias badge first, then the chip strip,
        // then the selected row.
        if noModifiers, keyCode == deleteKeyCode, c.searchTextIsEmpty {
            if c.isAliasActive { return .exitAliasMode }
            if c.hasScopeChips { return .backspaceIntoChips }
            if c.selectedIndex >= 0 {
                switch c.selectedRow {
                case .stackSlot: return .closeStackSlot
                case .liveTab: return .removeTab
                default: break
                }
            }
        }

        // Tab/Space commit a typed keyword into alias mode.
        if noModifiers, !c.isScopeDropdownVisible, !c.isAliasActive, !c.searchTextIsEmpty,
           keyCode == tabKeyCode || keyCode == spaceKeyCode, c.aliasCommittableByKey {
            return .commitAlias
        }

        // Esc / arrows / Return: the scope dropdown and chip strip go first.
        if keyCode == escapeKeyCode {
            if c.isScopeDropdownVisible { return .dismissScopeDropdown }
            if c.isChipFocused { return .unfocusChip }
        }
        if noModifiers, c.isScopeDropdownVisible {
            if keyCode == upArrowKeyCode { return .moveScopeSuggestion(by: -1) }
            if keyCode == downArrowKeyCode { return .moveScopeSuggestion(by: 1) }
        }
        if keyCode == returnKeyCode, c.isScopeDropdownVisible, hooks.scopeDropdownEnter() {
            return .consumed
        }

        // Everything else is the shared bar's generic routing.
        let state = CommandBarKeyState(selectedIndex: c.selectedIndex, queryIsEmpty: c.searchTextIsEmpty)
        guard let intent = CommandBarKeyRouter.intent(for: press, state: state) else { return .passThrough }
        switch intent {
        case .moveSelection(let direction, let source):
            return .moveSelection(forward: direction == .forward, via: source == .space ? .space : .upDown)
        case .swipe(let direction):
            return .keyboardSwipe(direction.revealedEdge)
        case .commit:
            return .activateSelection
        case .clearSelection:
            return .clearSelection
        case .close:
            return .hideBar
        }
    }

    /// Next selection for an arrow/Space/cycle step. `-1` is the search field.
    /// Returns the new index and whether the search field should take focus.
    static func movedSelection(from index: Int, forward: Bool, itemCount: Int, includeSearchField: Bool) -> (index: Int, focusSearch: Bool) {
        CommandBarController.movedSelection(
            from: index,
            direction: forward ? .forward : .backward,
            itemCount: itemCount,
            includeSearchField: includeSearchField
        )
    }
}
