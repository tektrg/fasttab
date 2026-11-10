import Foundation
import IndieCommandBar

/// Fast Tab's pages as shared `CommandBarViewTab`s (id = `CommandBarView.rawValue`)
/// and the custom-view context menu.
extension CommandBarViewTab {
    /// The page this tab stands for.
    var view: CommandBarView? { CommandBarView(rawValue: id) }

    /// Header tabs for `ordered` (swipe order). Recents shows as the search
    /// magnifier, as it always has. New View has no ⌘N.
    static func tabs(for ordered: [CommandBarView], customViews: [CustomView]) -> [CommandBarViewTab] {
        let numbers = CommandBarViewOrder.shortcutNumbers(for: ordered) { $0 != .newView }
        return zip(ordered, numbers).map { view, shortcut in
            let title = view == .recents ? "Search" : view.displayName(customViews: customViews)
            let base: String
            switch view {
            case .recents: base = "Search"
            case .stack: base = "Open Stack"
            case .custom, .newView: base = title
            }
            return CommandBarViewTab(
                id: view.rawValue,
                title: title,
                symbol: view == .recents ? "magnifyingglass" : view.iconName(customViews: customViews),
                isEditable: view.customID != nil,
                shortcutNumber: shortcut,
                help: shortcut.map { "\(base) (⌘\($0))" } ?? base
            )
        }
    }
}

/// Context menu of a header tab: Edit / Delete on custom views only.
enum FastTabViewMenu {
    static let editID = "view.edit"
    static let deleteID = "view.delete"

    static func actions(for tab: CommandBarViewTab) -> [CommandBarRowAction] {
        guard tab.isEditable else { return [] }
        return [
            CommandBarRowAction(id: editID, title: "Edit View…", symbol: "pencil"),
            CommandBarRowAction(id: deleteID, title: "Delete View…", symbol: "trash", role: .destructive),
        ]
    }
}
