import CoreGraphics

/// Where the corner tab's window sits. Pure.
enum CornerTabPlacement {
    static let tabWidth: CGFloat = 340
    static let tabHeight: CGFloat = 40
    /// The card mode's own slim header bar (dot + "waiting for your answer" + expand), the same
    /// height as the pill so the two feel like one family.
    static let cardHeaderHeight: CGFloat = tabHeight
    /// Card mode's total height: its header, a divider, the same card body height the main panel
    /// gives a card, and the same footer (hints/notice).
    static let cardHeight: CGFloat =
        cardHeaderHeight + AgentPanelMetrics.dividerHeight + AgentPanelMetrics.fullBodyHeight() + AgentPanelMetrics.footerHeight

    /// The window runs from the tab's left edge to the display's right edge, so
    /// the tab (which keeps the panel's edge margin) can slide in from the edge
    /// and is clipped by the window instead of spilling onto the next display.
    /// Same bottom margin as the panel.
    static func windowFrame(in visibleFrame: CGRect) -> CGRect {
        frame(width: tabWidth, height: tabHeight, in: visibleFrame)
    }

    /// Same bottom-right anchor as the pill, but sized for the live card: wider (the panel's own
    /// width) and taller, growing upward like `AgentPanelPlacement.frame`.
    static func cardWindowFrame(in visibleFrame: CGRect) -> CGRect {
        frame(width: AgentPanelMetrics.width, height: cardHeight, in: visibleFrame)
    }

    private static func frame(width: CGFloat, height: CGFloat, in visibleFrame: CGRect) -> CGRect {
        let margin = AgentPanelPlacement.edgeMargin
        let maxHeight = max(0, visibleFrame.height - margin * 2)
        return CGRect(
            x: visibleFrame.maxX - margin - width,
            y: visibleFrame.minY + margin,
            width: width + margin,
            height: min(height, maxHeight)
        )
    }
}
