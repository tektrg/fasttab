import CoreGraphics

/// Where the panel sits on a display. Pure.
enum AgentPanelPlacement {
    /// Gap between the panel and the display's right and bottom edges.
    static let edgeMargin: CGFloat = 20

    /// Bottom-right corner of `visibleFrame` (AppKit coordinates, y up), with the
    /// bottom edge fixed so the panel grows upward as rows appear instead of
    /// jumping around.
    static func frame(size: CGSize, in visibleFrame: CGRect) -> CGRect {
        let maxHeight = max(0, visibleFrame.height - edgeMargin * 2)
        let height = min(size.height, maxHeight)
        return CGRect(
            x: visibleFrame.maxX - edgeMargin - size.width,
            y: visibleFrame.minY + edgeMargin,
            width: size.width,
            height: height
        )
    }
}
