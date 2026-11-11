import SwiftUI
import CommandBarKit

/// One entry of the header view switcher (`SearchHeader`).
typealias CommandBarViewTab = CommandBarPageTab<FastTabBuiltinPage>

extension CommandBarPageTab where Builtin == FastTabBuiltinPage {
    var view: CommandBarView { page }

    /// Header tabs for `ordered` (swipe order). Recents shows as the search
    /// magnifier, as it always has.
    static func tabs(for ordered: [CommandBarView], customViews: [CustomView]) -> [Self] {
        tabs(for: ordered) { view in
            switch view {
            case .builtin(.recents): return ("Search", "magnifyingglass", "Search")
            case .builtin(.stack): return (view.displayName(customViews: customViews), view.iconName(customViews: customViews), "Open Stack")
            case .custom, .newView: return (view.displayName(customViews: customViews), view.iconName(customViews: customViews), nil)
            }
        }
    }
}

/// Fast Tab's header strip: the shared `CommandBarPageTabStrip` with the
/// custom-view context menu wired to the editor.
struct CommandBarViewTabStrip: View {
    let tabs: [CommandBarViewTab]
    let activeView: CommandBarView
    let highlight: Namespace.ID
    let onSelect: (CommandBarView) -> Void
    let capsInlineIcons: Bool

    var body: some View {
        CommandBarPageTabStrip(
            tabs: tabs,
            activePage: activeView,
            highlight: highlight,
            onSelect: onSelect,
            capsInlineIcons: capsInlineIcons,
            onEditView: { CustomViewEditorPresenter.shared.presentEdit(id: $0) },
            onDeleteView: { CustomViewEditorPresenter.shared.requestDelete(id: $0) }
        )
    }
}
