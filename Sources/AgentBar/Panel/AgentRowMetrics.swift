import AppKit

/// Height of an agent row whose status line (the recap, the question asked…) wraps onto several
/// lines. A row is never shorter than `AgentPanelMetrics.rowHeight`; each extra wrapped line adds
/// one line of the status font. The window total (`AgentPanelMetrics.listContentHeight`) uses the
/// same figure, so the list grows with the text. It is a measured estimate (the real row grows to
/// fit its text on its own, and the list scrolls), so a small mismatch can never clip or overlap.
enum AgentRowMetrics {
    /// Fixed chrome left of the text, from `AgentRowView`: list gutter (10+10), row padding (12+12),
    /// status dot (9) and its gap (10), plus slack for the rounded corner / scroller.
    private static let horizontalChrome: CGFloat = 10 * 2 + 12 * 2 + 9 + 10 + 8
    private static let childIndent: CGFloat = 20
    private static let statusFontSize: CGFloat = 12

    /// Rows the status text wraps into at the panel width (at least 1).
    static func statusLineCount(_ text: String, nesting: AgentRowNesting, width: CGFloat = AgentPanelMetrics.width) -> Int {
        let font = statusFont()
        let available = max(80, width - horizontalChrome - indent(of: nesting))
        let oneLine = lineHeight(font)
        guard !text.isEmpty, oneLine > 0 else { return 1 }
        let box = (text as NSString).boundingRect(
            with: CGSize(width: available, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        return max(1, Int((box.height / oneLine).rounded()))
    }

    static func height(of agent: AgentSnapshot, nesting: AgentRowNesting) -> CGFloat {
        let lines = statusLineCount(agent.statusText, nesting: nesting)
        guard lines > 1 else { return AgentPanelMetrics.rowHeight }
        return AgentPanelMetrics.rowHeight + CGFloat(lines - 1) * lineHeight(statusFont())
    }

    private static func indent(of nesting: AgentRowNesting) -> CGFloat {
        if case .child = nesting { return childIndent }
        return 0
    }

    private static func lineHeight(_ font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }

    /// Same family and scale as `Font.avenir(size: 12)` in the row.
    private static func statusFont() -> NSFont {
        let usesAvenir = UserDefaults.standard.object(forKey: AgentBarSettings.usesAvenirFontKey) as? Bool ?? true
        let size = statusFontSize * AgentBarSettings.currentFontScale()
        if usesAvenir, let avenir = NSFont(name: "Avenir Next", size: size) { return avenir }
        return NSFont.systemFont(ofSize: size)
    }
}
