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
    /// Rows shown before the list scrolls, out of the box (a user setting).
    static let defaultMaxVisibleRows = 9
    /// Section headers assumed when turning a row count into a height: the
    /// list has up to four sections, three is the usual busy case.
    private static let typicalHeaderCount = 3
    /// Default height beyond which the list scrolls (520pt: nine rows + three headers).
    static let maxListHeight: CGFloat = maxListHeight(visibleRows: defaultMaxVisibleRows)
    static let noteHeight: CGFloat = 30
    static let messageHeight: CGFloat = 170
    /// The always-present footer: hints, any notice (failed switch / shortcut
    /// problem) and the settings button.
    static let footerHeight: CGFloat = 30

    /// Peek (Space): header, then the screen text, then the "read at" line.
    static let peekHeaderHeight: CGFloat = 40
    static let peekTextLineHeight: CGFloat = 14
    static let peekTextVerticalPadding: CGFloat = 6
    static let peekReadLineHeight: CGFloat = 26

    /// The list height beyond which it scrolls, for a "rows before scrolling" choice.
    static func maxListHeight(visibleRows: Int) -> CGFloat {
        CGFloat(visibleRows) * rowHeight + CGFloat(typicalHeaderCount) * headerHeight + listVerticalPadding * 2
    }

    /// Total window height for what is being shown.
    static func height(
        for presentation: AgentListPresentation,
        maxListHeight: CGFloat = maxListHeight,
        isPeeking: Bool = false
    ) -> CGFloat {
        let note = presentation.showsBoardNote ? noteHeight : 0
        let body = isPeeking ? peekBodyHeight(maxListHeight: maxListHeight) : bodyHeight(for: presentation, maxListHeight: maxListHeight)
        return searchFieldHeight + dividerHeight + body + note + footerHeight
    }

    /// A peek replaces the list at the list's full height, so a short list
    /// still gives the screen text room.
    static func peekBodyHeight(maxListHeight: CGFloat = maxListHeight) -> CGFloat {
        maxListHeight
    }

    /// Whole screen-text lines that fit in a peek of `bodyHeight`.
    static func peekVisibleLineCount(bodyHeight: CGFloat) -> Int {
        let textHeight = bodyHeight - peekHeaderHeight - peekReadLineHeight - 2 * peekTextVerticalPadding
        return max(0, Int(textHeight / peekTextLineHeight))
    }

    static func bodyHeight(for presentation: AgentListPresentation, maxListHeight: CGFloat = maxListHeight) -> CGFloat {
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
