import CoreGraphics

/// Sizes shared by the views and the window. The panel's window frame is
/// computed from these (it is NOT auto-sized), so every view must fit the
/// heights declared here or it clips.
enum AgentPanelMetrics {
    static let width: CGFloat = 660
    static let searchFieldHeight: CGFloat = 54
    static let dividerHeight: CGFloat = 1
    static let rowHeight: CGFloat = 46
    static let headerHeight: CGFloat = 30
    static let listVerticalPadding: CGFloat = 8
    /// Beyond this the list scrolls (about ten rows with the headers).
    static let maxListHeight: CGFloat = 520
    static let noteHeight: CGFloat = 30
    static let messageHeight: CGFloat = 170
    /// The footer notice strip (failed switch / shortcut problem).
    static let footerHeight: CGFloat = 30

    /// Total window height for what is being shown.
    static func height(for presentation: AgentListPresentation, hasFooterNotice: Bool = false) -> CGFloat {
        let note = presentation.showsBoardNote ? noteHeight : 0
        let footer = hasFooterNotice ? footerHeight : 0
        return searchFieldHeight + dividerHeight + bodyHeight(for: presentation) + note + footer
    }

    static func bodyHeight(for presentation: AgentListPresentation) -> CGFloat {
        switch presentation.state {
        case .list: min(listContentHeight(for: presentation.rows), maxListHeight)
        case .connecting, .feedDown, .noAgents, .noMatches: messageHeight
        }
    }

    static func listContentHeight(for rows: [AgentListRow]) -> CGFloat {
        let content = rows.reduce(CGFloat(0)) { total, row in
            switch row {
            case .header: total + headerHeight
            case .agent: total + rowHeight
            }
        }
        return content + listVerticalPadding * 2
    }
}
