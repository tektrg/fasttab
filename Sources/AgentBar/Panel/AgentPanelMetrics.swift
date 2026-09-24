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

    /// Search field growth (Task: routing composes a longer message than a plain search). The field
    /// grows vertically with its content (`TextField(axis: .vertical)`, capped at this many lines) and
    /// the routing state (Jev thinking / confirming) gets its own row underneath rather than squeezed
    /// beside the field. Neither grows the window: `height(for:searchFieldLineCount:showsRoutingRow:)`
    /// subtracts the growth from the content area's height (list OR a flat message state) so the total
    /// stays put, whether or not the list happens to already be clamped at `maxListHeight`.
    static let searchFieldMaxLines = 4
    /// Extra height per line beyond the first.
    static let searchFieldLineHeight: CGFloat = 20
    /// The routing-state row (spinner + "Asking Jev…", or "→ target agent").
    static let routingRowHeight: CGFloat = 20

    /// Rough estimate of how many lines `text` wraps into at the field's width and font — good
    /// enough to reserve height for, not exact text layout. Newlines only ever come from a paste
    /// (Return is consumed to drive send/routing, never typed as a line break); each source line
    /// counts as at least one wrapped line.
    static func searchFieldLineCount(for text: String, charactersPerLine: Int = 46) -> Int {
        guard !text.isEmpty else { return 1 }
        let lines = text.components(separatedBy: .newlines).reduce(0) { total, line in
            total + max(1, Int((Double(line.count) / Double(charactersPerLine)).rounded(.up)))
        }
        return min(max(lines, 1), searchFieldMaxLines)
    }

    /// The field's own height for `lineCount` lines of content (1 = the original single-line height).
    static func searchFieldHeight(forLineCount lineCount: Int) -> CGFloat {
        searchFieldHeight + CGFloat(max(0, min(lineCount, searchFieldMaxLines) - 1)) * searchFieldLineHeight
    }

    /// Peek (Space): header, then the screen text, then the "read at" line.
    static let peekHeaderHeight: CGFloat = 40
    static let peekTextLineHeight: CGFloat = 14
    static let peekTextVerticalPadding: CGFloat = 6
    static let peekReadLineHeight: CGFloat = 26

    /// Answer card: the header and the bar with the Send button; the message,
    /// question and options share what is left.
    static let answerHeaderHeight: CGFloat = 40
    static let answerBottomBarHeight: CGFloat = 44

    /// The list height beyond which it scrolls, for a "rows before scrolling" choice.
    static func maxListHeight(visibleRows: Int) -> CGFloat {
        CGFloat(visibleRows) * rowHeight + CGFloat(typicalHeaderCount) * headerHeight + listVerticalPadding * 2
    }

    /// Total window height for what is being shown. `searchFieldLineCount` > 1 and/or
    /// `showsRoutingRow` grow the top of the panel; both are subtracted from the content area's
    /// height below (the list OR a flat message state) so the total stays put (see the doc comment
    /// above `searchFieldMaxLines`). This must hold whether the content area's natural height is
    /// already at `maxListHeight` (a long, scrolling list) or well under it (a short list, or any of
    /// the flat message states) — a `min(natural, reducedCap)` clamp only fixes the former, so the
    /// growth is subtracted from the content area's own (unclamped) height instead, uniformly.
    static func height(
        for presentation: AgentListPresentation,
        maxListHeight: CGFloat = maxListHeight,
        isPeeking: Bool = false,
        isAnswering: Bool = false,
        /// Tab-tagged (`AgentPanelModel.taggedAgentID`): the tag itself shows inline in the search
        /// field (a chip, no extra row), and the list/status message below is hidden entirely —
        /// nothing to pick from while composing a message to an already-chosen agent. The window
        /// shrinks to just the search field (which still grows with a longer typed message) plus the
        /// footer.
        isComposing: Bool = false,
        searchFieldLineCount: Int = 1,
        showsRoutingRow: Bool = false
    ) -> CGFloat {
        let note = (presentation.showsBoardNote && !isComposing) ? noteHeight : 0
        let fieldHeight = searchFieldHeight(forLineCount: searchFieldLineCount)
        let routingRow = showsRoutingRow ? routingRowHeight : 0
        let growth = (fieldHeight - searchFieldHeight) + routingRow
        let naturalBody: CGFloat = isComposing
            ? 0
            : isPeeking || isAnswering
                ? fullBodyHeight(maxListHeight: maxListHeight)
                : bodyHeight(for: presentation, maxListHeight: maxListHeight)
        let body = max(0, naturalBody - growth)
        return fieldHeight + routingRow + dividerHeight + body + note + footerHeight
    }

    /// A peek or an answer card replaces the list at the list's full height, so
    /// a short list still gives the screen text or the question room.
    static func fullBodyHeight(maxListHeight: CGFloat = maxListHeight) -> CGFloat {
        maxListHeight
    }

    static func peekBodyHeight(maxListHeight: CGFloat = maxListHeight) -> CGFloat {
        fullBodyHeight(maxListHeight: maxListHeight)
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
            case .header, .groupHeader: total + headerHeight
            case .agent: total + rowHeight
            }
        }
        return content + listVerticalPadding * 2
    }
}
