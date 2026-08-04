import CoreGraphics
import SwiftUI
import AppKit

enum CommandBarLayout {
    static let surfaceWidth: CGFloat = 640
    /// Half-width sliver for the left/right edge anchors.
    static let edgeSurfaceWidth: CGFloat = surfaceWidth / 2
    static let surfaceCornerRadius: CGFloat = 24
    static let defaultCanvasSize = CGSize(width: 1600, height: 1000)
    static let shadowOverscan: CGFloat = 900
    static let shadowEndRadius: CGFloat = 520

    /// Everything in the surface other than the results list: search header,
    /// footer, inter-section spacing, and the surface's own padding. The
    /// compact (edge) allowance is larger because the footer's hints and status
    /// text wrap onto extra lines at half width.
    private static let chromeAllowance: CGFloat = 170
    private static let compactChromeAllowance: CGFloat = 200

    /// One results row, including the spacing below it. Sized for the common
    /// case where the metadata line wraps (long URLs push onto a third line),
    /// not just the bare title + single metadata line. Compact rows are taller
    /// still because titles also wrap to two lines at half width.
    private static let resultRowHeight: CGFloat = 66
    private static let compactResultRowHeight: CGFloat = 80

    /// Rows the results list shows without scrolling — matches the quick-open
    /// display limit in `ContentView`, so the whole default list is visible.
    private static let visibleResultRows: CGFloat = 5

    static var minimumCanvasSize: CGSize { surfaceSize(for: .notch) }

    static func isCompact(_ anchor: EdgeRevealStyle) -> Bool {
        switch anchor {
        case .off, .notch:            return false
        case .leftEdge, .rightEdge:   return true
        }
    }

    /// Height of the scrollable results list — sized so the default five
    /// quick-open rows all fit without scrolling.
    static func resultsHeight(for anchor: EdgeRevealStyle) -> CGFloat {
        (isCompact(anchor) ? compactResultRowHeight : resultRowHeight) * visibleResultRows
    }

    static func surfaceSize(for anchor: EdgeRevealStyle) -> CGSize {
        let compact = isCompact(anchor)
        return CGSize(
            width: compact ? edgeSurfaceWidth : surfaceWidth,
            // The notch anchor sits flush against the top of the display, so
            // the physical notch (or the menu bar) would otherwise sit on top
            // of the search field — the surface grows by that much and pads
            // its content down to clear it (see `surfaceTopInset`).
            height: (compact ? compactChromeAllowance : chromeAllowance)
                + resultsHeight(for: anchor)
                + surfaceTopInset(for: anchor)
        )
    }

    /// Dead space reserved at the top of the notch-anchored surface so content
    /// starts below a *physical* notch instead of underneath it.
    ///
    /// Zero unless the display actually has a notch:
    /// - Edge anchors are vertically centered and never reach the top.
    /// - Displays with no notch (external monitors, clamshell, older MacBooks)
    ///   have nothing to clear. The bar draws above the menu-bar layer, so
    ///   reserving space there only read as an empty band at the top of the
    ///   panel — which is exactly what it looked like.
    static func surfaceTopInset(for anchor: EdgeRevealStyle) -> CGFloat {
        guard !isCompact(anchor) else { return 0 }
        guard let screen = notchClearanceScreen else { return 0 }
        let info = EdgeRevealGeometry.screenInfo(for: screen)
        guard info.hasPhysicalNotch else { return 0 }
        return EdgeRevealGeometry.notchZone(info).height
    }

    /// The display the notch-anchored bar will open on — the one under the
    /// pointer, matching `preferredCommandBarDisplay(preferMouseScreen:)`. Using
    /// `NSScreen.main` alone reserved (or skipped) notch clearance based on
    /// whichever display had keyboard focus, which is the wrong one whenever the
    /// bar opens on the other display of a two-display setup.
    private static var notchClearanceScreen: NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main
    }

    static func canvasFrame(for displayFrame: CGRect) -> CGRect {
        let canvasSize = CGSize(
            width: max(displayFrame.width, minimumCanvasSize.width),
            height: max(displayFrame.height, minimumCanvasSize.height)
        )

        return CGRect(
            x: displayFrame.midX - canvasSize.width / 2,
            y: displayFrame.midY - canvasSize.height / 2,
            width: canvasSize.width,
            height: canvasSize.height
        )
    }

    /// SwiftUI-space offset (y-down) that flushes the surface against
    /// whichever screen edge `anchor` hugs — notch flush to the top, edges
    /// flush to their side — matching the trigger's own shape (see
    /// `surfaceCorners`).
    static func surfaceOffset(canvasSize: CGSize, anchor: EdgeRevealStyle) -> CGSize {
        let size = surfaceSize(for: anchor)
        switch anchor {
        case .off, .notch:
            return CGSize(width: 0, height: -(canvasSize.height - size.height) / 2)
        case .leftEdge:
            return CGSize(width: -(canvasSize.width - size.width) / 2, height: 0)
        case .rightEdge:
            return CGSize(width: (canvasSize.width - size.width) / 2, height: 0)
        }
    }

    static func surfaceFrame(in canvasFrame: CGRect, anchor: EdgeRevealStyle) -> CGRect {
        let size = surfaceSize(for: anchor)
        let offset = surfaceOffset(canvasSize: canvasFrame.size, anchor: anchor)
        return CGRect(
            // AppKit screen coordinates are y-up; SwiftUI's offset is y-down,
            // so the vertical component flips sign going from one to the other.
            x: canvasFrame.midX - size.width / 2 + offset.width,
            y: canvasFrame.midY - size.height / 2 - offset.height,
            width: size.width,
            height: size.height
        )
    }

    static func shouldDismissClick(at screenLocation: CGPoint, in canvasFrame: CGRect, anchor: EdgeRevealStyle) -> Bool {
        !surfaceFrame(in: canvasFrame, anchor: anchor).contains(screenLocation)
    }

    static func shadowBackdropSize(for canvasSize: CGSize) -> CGSize {
        CGSize(
            width: canvasSize.width + shadowOverscan,
            height: canvasSize.height + shadowOverscan
        )
    }

    /// Per-corner radii for the outer surface shape: flat on the side
    /// `anchor` hugs, rounded on the rest — the same half-capsule silhouette
    /// as the trigger itself (see `EdgeRevealPeekView`).
    static func surfaceCorners(for anchor: EdgeRevealStyle) -> (topLeading: CGFloat, bottomLeading: CGFloat, bottomTrailing: CGFloat, topTrailing: CGFloat) {
        let r = surfaceCornerRadius
        switch anchor {
        case .off, .notch:
            return (0, r, r, 0)
        case .leftEdge:
            return (0, 0, r, r)
        case .rightEdge:
            return (r, r, 0, 0)
        }
    }

    /// SwiftUI anchor the grow-from-edge reveal animation scales around —
    /// matches whichever side `surfaceCorners` leaves flat.
    static func revealAnchorUnitPoint(for anchor: EdgeRevealStyle) -> UnitPoint {
        switch anchor {
        case .off, .notch:
            return .top
        case .leftEdge:
            return .leading
        case .rightEdge:
            return .trailing
        }
    }

    /// Starting (pre-animation) scale for the grow-from-edge reveal: a thin
    /// sliver along the hugged edge that springs open to full size — notch
    /// reveals are flat and wide, edge reveals are flat and tall.
    static func revealInitialScale(for anchor: EdgeRevealStyle) -> CGSize {
        switch anchor {
        case .off, .notch:
            return CGSize(width: 0.35, height: 0.12)
        case .leftEdge, .rightEdge:
            return CGSize(width: 0.12, height: 0.35)
        }
    }
}
