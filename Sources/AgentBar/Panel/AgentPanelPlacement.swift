import CoreGraphics

/// Where the panel sits on a display. Pure.
enum AgentPanelPlacement {
    /// Fraction of the display's height left above the panel's top edge.
    static let topGapFraction: CGFloat = 0.14

    /// Horizontally centred, top edge fixed a bit below the top of
    /// `visibleFrame` (AppKit coordinates, y up) so the panel grows downward
    /// as rows appear instead of jumping around.
    static func frame(size: CGSize, in visibleFrame: CGRect) -> CGRect {
        let top = visibleFrame.maxY - visibleFrame.height * topGapFraction
        let maxHeight = max(0, top - visibleFrame.minY - 20)
        let height = min(size.height, maxHeight)
        return CGRect(
            x: visibleFrame.midX - size.width / 2,
            y: top - height,
            width: size.width,
            height: height
        )
    }
}
