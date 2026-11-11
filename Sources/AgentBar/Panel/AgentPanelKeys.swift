import SwiftUI

/// The search box's key decisions, kept pure so tests pin them (the view only calls these).
/// Agent-only keys: Shift+Return routing, card digits, ⌘C on a card, Esc's layers, and the
/// hidden ⌘F / ⌘] / ⌘[ / ⌘⌫ / ⌘1…⌘9 shortcuts.
enum AgentPanelKeys {
    enum ReturnAction: Equatable { case startRouting, activateSelected }

    /// Shift+Return over free text starts Jev routing unless a card owns the keyboard.
    static func returnAction(shift: Bool, isCardOpen: Bool) -> ReturnAction {
        !isCardOpen && shift ? .startRouting : .activateSelected
    }

    enum CardKey: Equatable {
        /// Not a card key: the field handles it.
        case ignored
        /// ⌘C: copy the open card's agent details.
        case copyIdentity
        /// 1–9: pick that option.
        case pickOption(Int)
        /// Any other character while a card is open is dropped.
        case dropStray
    }

    /// While a card is open the box types nothing: digits pick, ⌘C copies, other characters drop.
    /// Navigation keys (arrows, space, return, escape, tab) keep their own handlers.
    static func cardKey(characters: String, modifiers: EventModifiers, isNavigationKey: Bool, isCardOpen: Bool) -> CardKey {
        guard isCardOpen else { return .ignored }
        if modifiers == .command, characters == "c" { return .copyIdentity }
        guard modifiers.subtracting(.shift).isEmpty, !isNavigationKey else { return .ignored }
        if let number = Int(characters), (1...9).contains(number) { return .pickOption(number) }
        return .dropStray
    }

    enum EscapeStep: Equatable { case dismissedNotice, backedOutOfButtons, closedPeek, closePanel }

    /// Esc peels one layer: a failure notice, then the row-button highlight, then the peek, then the panel.
    static func escape(dismissNotice: () -> Bool, backOutOfButtons: () -> Bool, hasPeek: Bool) -> EscapeStep {
        if dismissNotice() { return .dismissedNotice }
        if backOutOfButtons() { return .backedOutOfButtons }
        return hasPeek ? .closedPeek : .closePanel
    }

    enum Shortcut: Hashable { case focus, reportTo, stopReporting, stopReportingDelete, page(Int) }

    /// The hidden window-wide shortcuts on offer right now.
    static func shortcuts(isNewWorker: Bool, focusCount: Int, queryIsEmpty: Bool, canSwitchPages: Bool) -> Set<Shortcut> {
        var keys: Set<Shortcut> = []
        if !isNewWorker {
            if focusCount > 0 { keys.insert(.focus) }
            keys.formUnion([.reportTo, .stopReporting])
            if queryIsEmpty { keys.insert(.stopReportingDelete) }
        }
        if canSwitchPages { (1...9).forEach { keys.insert(.page($0)) } }
        return keys
    }
}
