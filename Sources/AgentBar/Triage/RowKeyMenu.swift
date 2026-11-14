import Foundation

/// ⌘K in the agent list: the selected row's ⋯ menu as a keyboard menu (gotcha 17: a native `Menu`
/// cannot be opened from code, so this is the keyboard path to the SAME items, `AgentActionList.menuItems`).
/// Numbered 1…9, ↑/↓ move (skipping nothing; a disabled item just won't fire), ↩ activates, a digit
/// quick-selects, Esc / ⌘K close only the menu. Pure.
struct RowKeyMenu: Equatable {
    let agentID: String
    let items: [RowButtonSpec]
    private(set) var highlighted: Int

    enum Key: Equatable { case up, down, enter, escape, toggle, digit(Int), other }
    enum Effect: Equatable {
        /// Key used, menu stays.
        case none
        case close
        /// Close the menu and press this button on the row (`AgentPanelModel.press`).
        case activate(RowButton)
    }

    /// Nil when the row's ⋯ menu would be empty (nothing to open).
    init?(agentID: String, items: [RowButtonSpec]) {
        guard !items.isEmpty else { return nil }
        self.agentID = agentID
        self.items = items
        highlighted = items.firstIndex(where: \.isEnabled) ?? 0
    }

    /// "1".."9" for the first nine items, nil after.
    static func number(at index: Int) -> String? { index < 9 ? String(index + 1) : nil }

    mutating func handle(_ key: Key) -> Effect {
        switch key {
        case .up: highlighted = max(0, highlighted - 1); return .none
        case .down: highlighted = min(items.count - 1, highlighted + 1); return .none
        case .escape, .toggle: return .close
        case .enter: return activate(highlighted)
        case .digit(let number):
            guard (1...min(9, items.count)).contains(number) else { return .none }
            highlighted = number - 1
            return activate(highlighted)
        case .other: return .none
        }
    }

    private func activate(_ index: Int) -> Effect {
        let spec = items[index]
        return spec.isEnabled ? .activate(spec.button) : .none
    }

    /// The key as the panel's key monitor sees it (macOS key codes). ⌘K toggles; other ⌘ keys are `.other`.
    static func key(keyCode: UInt16, characters: String, command: Bool) -> Key {
        if command { return characters.lowercased() == "k" ? .toggle : .other }
        switch keyCode {
        case 126: return .up
        case 125: return .down
        case 36, 76: return .enter
        case 53: return .escape
        default:
            if let number = Int(characters), (1...9).contains(number) { return .digit(number) }
            return .other
        }
    }
}
