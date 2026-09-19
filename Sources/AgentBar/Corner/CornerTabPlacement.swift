import CoreGraphics

/// Where the corner tab's window sits. Pure.
enum CornerTabPlacement {
    static let tabWidth: CGFloat = 340
    static let tabHeight: CGFloat = 40

    /// The window runs from the tab's left edge to the display's right edge, so
    /// the tab (which keeps the panel's edge margin) can slide in from the edge
    /// and is clipped by the window instead of spilling onto the next display.
    /// Same bottom margin as the panel.
    static func windowFrame(in visibleFrame: CGRect) -> CGRect {
        let margin = AgentPanelPlacement.edgeMargin
        return CGRect(
            x: visibleFrame.maxX - margin - tabWidth,
            y: visibleFrame.minY + margin,
            width: tabWidth + margin,
            height: tabHeight
        )
    }
}
