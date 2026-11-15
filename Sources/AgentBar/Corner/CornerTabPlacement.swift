import CoreGraphics
import IndieEdgeReveal
import SwiftUI

/// Which screen edge the corner tab slides in from, set by the hover spot it sits at.
/// Corners and the left/right edges slide sideways; the notch and bottom edge slide vertically.
enum CornerTabSlide: Equatable {
    case fromRight, fromLeft, fromTop, fromBottom

    init(spot: EdgeRevealStyle) {
        switch CornerTabPlacement.placementSpot(for: spot) {
        case .topLeftCorner, .bottomLeftCorner, .leftEdge: self = .fromLeft
        case .notch: self = .fromTop
        case .bottomEdge: self = .fromBottom
        case .topRightCorner, .bottomRightCorner, .rightEdge, .off: self = .fromRight
        }
    }

    var isHorizontal: Bool { self == .fromRight || self == .fromLeft }

    /// Where the content sits in its window: against the margin side, leaving the edge side free to slide through.
    var contentAlignment: Alignment {
        switch self {
        case .fromRight: .leading
        case .fromLeft: .trailing
        case .fromTop: .bottom
        case .fromBottom: .top
        }
    }

    /// The offset that parks content of `size` (plus the margin) outside its window.
    func hiddenOffset(for size: CGSize) -> CGSize {
        let margin = AgentPanelPlacement.edgeMargin
        switch self {
        case .fromRight: return CGSize(width: size.width + margin, height: 0)
        case .fromLeft: return CGSize(width: -(size.width + margin), height: 0)
        case .fromTop: return CGSize(width: 0, height: -(size.height + margin))
        case .fromBottom: return CGSize(width: 0, height: size.height + margin)
        }
    }

    /// The window around content of `size`: the content plus the margin on the edge side.
    func windowSize(for size: CGSize) -> CGSize {
        let margin = AgentPanelPlacement.edgeMargin
        return isHorizontal
            ? CGSize(width: size.width + margin, height: size.height)
            : CGSize(width: size.width, height: size.height + margin)
    }
}

/// Where the corner tab's window sits for a hover spot. Pure. The window is placed with the shared
/// flush placement (`EdgeRevealGeometry.flushSurfaceFrame`) for that spot, so the tab and the panel
/// agree on edges and corners with every other app.
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

    /// "Hover to open: Off" has no spot to sit at: arrivals still slide in from the bottom-right,
    /// where the tab always was.
    static func placementSpot(for spot: EdgeRevealStyle) -> EdgeRevealStyle {
        spot == .off ? .bottomRightCorner : spot
    }

    /// The pill's window: from the tab to the screen edge it slides in from (the window clips the
    /// slide, so the tab never spills onto the next display), the panel's edge margin on the other sides.
    static func windowFrame(in visibleFrame: CGRect, spot: EdgeRevealStyle = .bottomRightCorner) -> CGRect {
        frame(width: tabWidth, height: tabHeight, in: visibleFrame, spot: spot)
    }

    /// Same anchor as the pill, sized for the live card: wider (the panel's own width) and taller.
    static func cardWindowFrame(in visibleFrame: CGRect, spot: EdgeRevealStyle = .bottomRightCorner) -> CGRect {
        frame(width: AgentPanelMetrics.width, height: cardHeight, in: visibleFrame, spot: spot)
    }

    private static func frame(width: CGFloat, height: CGFloat, in visibleFrame: CGRect, spot: EdgeRevealStyle) -> CGRect {
        let spot = placementSpot(for: spot)
        let slide = CornerTabSlide(spot: spot)
        let margin = AgentPanelPlacement.edgeMargin
        let size = slide.windowSize(for: CGSize(width: width, height: min(height, max(0, visibleFrame.height - margin * 2))))
        // The slide edge is flush with the screen; the other sides keep the margin.
        let area = slide.isHorizontal ? visibleFrame.insetBy(dx: 0, dy: margin) : visibleFrame.insetBy(dx: margin, dy: 0)
        let centre = CGRect(x: visibleFrame.midX, y: visibleFrame.midY, width: 0, height: 0)
        return EdgeRevealGeometry.flushSurfaceFrame(for: spot, size: size, zone: centre, screenFrame: area) ?? .zero
    }
}
