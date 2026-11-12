import IndieCommandBar

/// What a Fast Tab row's ⋯ menu lists, as shared row actions (IndieCommandBar `RowActionMenu`).
/// ⌘C runs the same `copy` action (`CommandBarRowAction.copyID`): it copies the row's URL.
/// Close/remove is not in the menu: it stays the one-click `RowCloseButton` beside it.
enum FastTabRowMenu {
    static let openID = "open"
    static let listBridgeID = "listBridge"
    static let pinID = "pin"

    /// A result row (tab, sent link, bookmark, history, FastTab List item).
    static func actions(for result: BrowserSearchResult, bridge: FastTabListRowBridge?, offersPin: Bool) -> [CommandBarRowAction] {
        var actions = [CommandBarRowAction(id: openID, title: openTitle(for: result), symbol: "arrow.up.right")]
        if let bridge {
            let key = bridge == .moveToBookmarks ? "⌘D" : "⌘S"
            actions.append(CommandBarRowAction(id: listBridgeID, title: "\(bridge.title) (\(key))", symbol: bridge.symbolName))
        }
        if result.type == .tab, offersPin {
            actions.append(CommandBarRowAction(id: pinID, title: result.isPinned ? "Unpin Tab" : "Pin Tab", symbol: "pin"))
        }
        actions.append(.copy(title: "Copy Link", symbol: "link"))
        return actions
    }

    /// A Stack slot (live, ghost or frozen tab).
    static func actions(for slot: OrderedTabSlot, bridge: FastTabListRowBridge?) -> [CommandBarRowAction] {
        var actions = [CommandBarRowAction(id: openID, title: openTitle(for: slot), symbol: "arrow.up.right")]
        if let bridge {
            actions.append(CommandBarRowAction(id: listBridgeID, title: "\(bridge.title) (⌘S)", symbol: bridge.symbolName))
        }
        actions.append(CommandBarRowAction(id: pinID, title: slot.isPinned ? "Unpin Tab" : "Pin Tab", symbol: "pin"))
        actions.append(.copy(title: "Copy URL", symbol: "link"))
        return actions
    }

    static func openTitle(for result: BrowserSearchResult) -> String {
        let name = result.browserName.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.isGhost { return name.isEmpty ? "Reopen Tab" : "Reopen in \(name)" }
        if result.type == .tab { return name.isEmpty ? "Switch to Tab" : "Open in \(name)" }
        return name.isEmpty ? "Open Link" : "Open in \(name)"
    }

    static func openTitle(for slot: OrderedTabSlot) -> String {
        let name = slot.browserName.trimmingCharacters(in: .whitespacesAndNewlines)
        switch slot.state {
        case .ghost: return name.isEmpty ? "Reopen Tab" : "Reopen in \(name)"
        case .browserFrozen: return "Open Link"
        case .live: return name.isEmpty ? "Switch to Tab" : "Open in \(name)"
        }
    }
}
