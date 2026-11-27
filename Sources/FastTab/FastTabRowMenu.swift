import IndieCommandBar

/// What a Fast Tab row's ⋯ menu lists, as shared row actions (IndieCommandBar `RowActionMenu`).
/// ⌘C runs the same `copy` action (`CommandBarRowAction.copyID`): it copies the row's URL.
/// Close/remove is not in the menu: it stays the one-click `RowCloseButton` beside it.
enum FastTabRowMenu {
    static let openID = "open"
    static let openInOtherBrowserID = "openInOtherBrowser"
    static let openInOtherBrowserPrefix = "openInOtherBrowser:"
    static let listBridgeID = "listBridge"
    static let pinID = "pin"

    static func openInOtherBrowserActionID(for browserName: String) -> String {
        openInOtherBrowserPrefix + browserName
    }

    static func otherBrowserName(from actionID: String) -> String? {
        guard actionID.hasPrefix(openInOtherBrowserPrefix) else { return nil }
        let name = String(actionID.dropFirst(openInOtherBrowserPrefix.count))
        return name.isEmpty ? nil : name
    }

    /// Other browsers available for "Open in Other Browser", excluding the tab's
    /// current browser and Finder, with the user's last-chosen browser placed first.
    static func otherBrowsers(
        excluding currentBrowserName: String,
        available: [String],
        lastChosen: String?
    ) -> [String] {
        var seen = Set<String>()
        var filtered: [String] = []
        for name in available {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  trimmed != "Finder",
                  trimmed != currentBrowserName,
                  seen.insert(trimmed).inserted else {
                continue
            }
            filtered.append(trimmed)
        }
        if let lastChosen,
           let idx = filtered.firstIndex(of: lastChosen),
           idx > 0 {
            let chosen = filtered.remove(at: idx)
            filtered.insert(chosen, at: 0)
        }
        return filtered
    }

    private static func otherBrowserMenuAction(browsers: [String]) -> CommandBarRowAction? {
        guard !browsers.isEmpty else { return nil }
        let items = browsers.map { browser in
            CommandBarRowAction(
                id: openInOtherBrowserActionID(for: browser),
                title: browser,
                symbol: "globe"
            )
        }
        return CommandBarRowAction(
            id: openInOtherBrowserID,
            title: "Open in Other Browser",
            symbol: "arrow.up.forward.app",
            submenu: [CommandBarRowActionSection(actions: items)]
        )
    }

    /// A result row (tab, sent link, bookmark, history, FastTab List item).
    static func actions(
        for result: BrowserSearchResult,
        bridge: FastTabListRowBridge?,
        offersPin: Bool,
        otherBrowsers: [String] = []
    ) -> [CommandBarRowAction] {
        var actions = [CommandBarRowAction(id: openID, title: openTitle(for: result), symbol: "arrow.up.right")]
        if result.type == .tab, result.isPinned, let submenu = otherBrowserMenuAction(browsers: otherBrowsers) {
            actions.append(submenu)
        }
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
    static func actions(
        for slot: OrderedTabSlot,
        bridge: FastTabListRowBridge?,
        otherBrowsers: [String] = []
    ) -> [CommandBarRowAction] {
        var actions = [CommandBarRowAction(id: openID, title: openTitle(for: slot), symbol: "arrow.up.right")]
        if slot.isPinned, let submenu = otherBrowserMenuAction(browsers: otherBrowsers) {
            actions.append(submenu)
        }
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
        case .browserFrozen: return name.isEmpty ? "Open Link" : "Open in \(name)"
        case .live: return name.isEmpty ? "Switch to Tab" : "Open in \(name)"
        }
    }
}
