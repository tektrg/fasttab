import Foundation

/// Which peek keys switch tabs (pure, 2026-11-15). Tab always toggles (as before). ← selects
/// Last message, → Terminal — but only when no text box has the keyboard, or the focused box
/// (search field or the peek's message box) is EMPTY. With text in it the arrows are the box's
/// (caret moves); Tab still switches. Modified arrows (⌘/⌥/⇧/⌃) are never the peek's.
enum PeekKeyRouting {
    enum Action: Equatable {
        case toggle
        case select(PanePeek.Tab)
    }

    static let tabKeyCode: UInt16 = 48
    static let leftKeyCode: UInt16 = 123
    static let rightKeyCode: UInt16 = 124

    /// `focusedText`: the text of the box that has the keyboard, nil when none does.
    /// `hasModifiers`: any of ⌘ ⌥ ⌃ ⇧ held. Nil = not the peek's key.
    static func action(keyCode: UInt16, hasModifiers: Bool, focusedText: String?) -> Action? {
        guard !hasModifiers else { return nil }
        switch keyCode {
        case tabKeyCode: return .toggle
        case leftKeyCode, rightKeyCode:
            guard (focusedText ?? "").isEmpty else { return nil }
            return .select(keyCode == leftKeyCode ? .lastMessage : .terminal)
        default: return nil
        }
    }
}
