import CoreGraphics
import IndieCommandBar

/// Where the panel sits on a display. Pure.
enum AgentPanelPlacement {
    /// Gap between the panel and the display's edges.
    static let edgeMargin: CGFloat = 20

    /// The panel's frame in `visibleFrame` (AppKit coordinates, y up) for the user's `placement`.
    /// Default bottom-right: the bottom edge stays fixed so the panel grows upward as rows
    /// appear instead of jumping around.
    static func frame(size: CGSize, in visibleFrame: CGRect, placement: CommandBarPlacement = .bottomRight) -> CGRect {
        placement.frame(size: size, in: visibleFrame, margin: edgeMargin)
    }
}
