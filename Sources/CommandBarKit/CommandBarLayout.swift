import AppKit
import SwiftUI
import IndieEdgeReveal
import IndieEdgeRevealUI

/// Anchor-driven geometry for a command bar that hugs a screen edge: widths,
/// the silhouette's radii, where it aligns and casts its shadow, and the
/// grow-from-edge reveal curve. Row heights and chrome allowances are the host
/// app's to decide, so it extends this with its own sizing.
public enum CommandBarLayout {
    public static let surfaceWidth: CGFloat = 640
    /// Half-width sliver for the left/right edge anchors.
    public static let edgeSurfaceWidth: CGFloat = surfaceWidth / 2
    public static let surfaceCornerRadius: CGFloat = 24

    /// Radius of the flare where the bar meets the screen edge it hugs — the
    /// same detail the MacBook notch uses where it meets the bezel. Small on
    /// purpose: at much more than this it stops reading as a moulded join and
    /// starts reading as two ears on the bar. See `EdgeRevealSurfaceShape`.
    public static let surfaceJoinRadius: CGFloat = 12
    public static let defaultCanvasSize = CGSize(width: 1600, height: 1000)
    public static let shadowOverscan: CGFloat = 900
    public static let shadowEndRadius: CGFloat = 520

    /// Minimal row style narrows the notch panel to this fraction of
    /// `surfaceWidth` by default — icon+title rows need far less width than
    /// the full metadata layout.
    public static let minimalWidthFraction: CGFloat = 2.0 / 3.0

    public static func isCompact(_ anchor: CommandBarAnchor) -> Bool {
        switch anchor {
        case .notch:            return false
        case .leftEdge, .rightEdge:   return true
        }
    }

    /// The panel width before any manual drag override — full width in Full
    /// row style, narrowed for Minimal, unaffected for the fixed-width edge
    /// anchors.
    public static func automaticWidth(for anchor: CommandBarAnchor, rowStyle: ResultRowStyle) -> CGFloat {
        guard !isCompact(anchor) else { return edgeSurfaceWidth }
        return rowStyle == .minimal ? surfaceWidth * minimalWidthFraction : surfaceWidth
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
    public static func surfaceTopInset(for anchor: CommandBarAnchor) -> CGFloat {
        guard !isCompact(anchor) else { return 0 }
        guard let screen = notchClearanceScreen else { return 0 }
        let info = EdgeRevealScreenInfo(screen: screen)
        guard info.hasPhysicalNotch else { return 0 }
        return EdgeRevealGeometry.notchZone(info).height
    }

    /// Width of the real physical notch, for the small black connector drawn
    /// in the clearance inset above the surface — kept notch-width,
    /// not the full (much wider) panel width, so it reads as the notch
    /// extending down a little rather than a wide black bar across the top.
    /// Zero under the same conditions as `surfaceTopInset` (nothing to draw).
    public static func notchConnectorWidth(for anchor: CommandBarAnchor) -> CGFloat {
        guard !isCompact(anchor) else { return 0 }
        guard let screen = notchClearanceScreen else { return 0 }
        let info = EdgeRevealScreenInfo(screen: screen)
        guard info.hasPhysicalNotch else { return 0 }
        return EdgeRevealGeometry.notchZone(info).width
    }

    /// The display the notch-anchored bar will open on — the one under the
    /// pointer, matching `NSWindow.fitCommandBarCanvasToVisibleScreen`. Using
    /// `NSScreen.main` alone reserved (or skipped) notch clearance based on
    /// whichever display had keyboard focus, which is the wrong one whenever the
    /// bar opens on the other display of a two-display setup.
    public static var notchClearanceScreen: NSScreen? {
        NSScreen.containing(NSEvent.mouseLocation) ?? NSScreen.main
    }

    /// How far the ambient shadow's source rectangle is pushed, before
    /// blurring, past the surface's own position in the direction the
    /// surface grows into (down for the notch, right/left for the edge
    /// anchors). A panel hinged on one edge only casts a shadow away from
    /// that hinge — shifting the shadow's source rectangle this far tucks
    /// its near edge entirely under the (opaque) surface, so almost none of
    /// the blur spread escapes past the flush/anchor edge, while the far
    /// edge gets the full spread plus this shift, reading as noticeably
    /// heavier. Value is tuned against `shadowBlurRadius` (roughly 1.3x it)
    /// so the near edge fully hides.
    public static let shadowDirectionalShift: CGFloat = 40

    /// Blur radius for the ambient shadow. Kept fairly tight (vs. a wide,
    /// soft cloud) so the shadow reads as a dense contact shadow hugging the
    /// panel's far edge rather than a diffuse haze — paired with
    /// `shadowDirectionalShift` above.
    public static let shadowBlurRadius: CGFloat = 30

    /// `shadowDirectionalShift` as a vector pointing the way the surface grows
    /// (down for the notch, right/left for the edge anchors).
    ///
    /// Applied *inside* the reveal's `scaleEffect`, not added to the shadow's
    /// outer offset: as a fixed outer offset it stayed a full 60pt while the
    /// panel was still a sliver, so the first frames of the reveal showed a
    /// detached dark blob hanging below the notch (or inboard of the edge)
    /// with a visible gap between it and the screen edge, before the panel
    /// caught up. Scaled along with everything else, the shadow stays tucked
    /// under the surface from the very first frame.
    public static func shadowShiftVector(for anchor: CommandBarAnchor) -> CGSize {
        switch anchor {
        case .notch:
            return CGSize(width: 0, height: shadowDirectionalShift)
        case .leftEdge:
            return CGSize(width: shadowDirectionalShift, height: 0)
        case .rightEdge:
            return CGSize(width: -shadowDirectionalShift, height: 0)
        }
    }

    public static func shadowBackdropSize(for canvasSize: CGSize) -> CGSize {
        CGSize(
            width: canvasSize.width + shadowOverscan,
            height: canvasSize.height + shadowOverscan
        )
    }

    /// Alignment that flushes the surface against the edge `anchor` hugs.
    ///
    /// This — not `surfaceOffset` — is what positions the live bar. Offsetting
    /// by half the difference between the canvas and the surface requires
    /// knowing the canvas size, and the only way to know it inside the view is
    /// to measure it (`GeometryReader`), which lags the window by a layout pass:
    /// the window is resized to the target display and ordered front in the same
    /// turn, so the first rendered frame still used the *previous* canvas size
    /// and drew the bar inset from its edge — 204pt inboard when moving between
    /// a 1512pt and a 1920pt-wide display, and dead centre on the first open
    /// after launch (canvas still 0x0) — snapping flush a frame later. An
    /// alignment is resolved by SwiftUI inside the same layout pass, so it is
    /// always consistent with the size the window actually has.
    public static func surfaceAlignment(for anchor: CommandBarAnchor) -> Alignment {
        switch anchor {
        case .notch:
            return .top
        case .leftEdge:
            return .leading
        case .rightEdge:
            return .trailing
        }
    }

    // The grow-from-edge reveal math lives in IndieEdgeRevealUI (`EdgeRevealMotion`), shared
    // with other apps; these forward to it so the bar's call sites keep their names.

    public static func revealAxis(from start: CGFloat, progress: Double) -> CGFloat {
        EdgeRevealMotion.axis(from: start, progress: progress)
    }

    public static let revealDepthSpring: Animation = EdgeRevealMotion.depthSpring
    public static let revealSpreadSpring: Animation = EdgeRevealMotion.spreadSpring
    public static let revealContentFadeRange: ClosedRange<Double> = EdgeRevealMotion.contentFadeRange
    public static let revealSurfaceFadeCeiling: Double = EdgeRevealMotion.surfaceFadeCeiling

    public static func revealContentOpacity(depthProgress: Double, spreadProgress: Double) -> Double {
        EdgeRevealMotion.contentOpacity(depth: depthProgress, spread: spreadProgress)
    }

    public static func revealSurfaceOpacity(depthProgress: Double, spreadProgress: Double) -> Double {
        EdgeRevealMotion.surfaceOpacity(depth: depthProgress, spread: spreadProgress)
    }

    /// The point the reveal scales around: the side the surface leaves flat.
    public static func revealAnchorUnitPoint(for anchor: CommandBarAnchor) -> UnitPoint {
        EdgeRevealMotion.anchorPoint(for: anchor.surfaceHug)
    }

    /// Starting (pre-animation) scale for the grow-from-edge reveal. Edge
    /// reveals have no physical landmark to match, so they keep a fixed thin
    /// sliver. The notch reveal instead matches the real notch's (or its fake
    /// stand-in's) exact width and height, so the animation starts perfectly
    /// hidden behind it rather than an arbitrarily-sized sliver that reads as
    /// wider than the notch and hanging below it.
    ///
    /// `surfaceSize` must be the *live* size the panel is actually rendered at.
    /// Deriving it from default settings instead made the ratio wrong by however
    /// much the user's real settings differ — the reveal could start ~1.5x
    /// smaller than the notch, or *larger* and hang visibly below it before the
    /// animation began.
    public static func revealInitialScale(for anchor: CommandBarAnchor, surfaceSize: CGSize) -> CGSize {
        switch anchor {
        case .notch:
            guard let screen = notchClearanceScreen, surfaceSize.width > 0, surfaceSize.height > 0 else {
                return CGSize(width: 0.35, height: 0.12)
            }
            let notch = EdgeRevealGeometry.notchZone(EdgeRevealScreenInfo(screen: screen))
            return EdgeRevealMotion.initialScale(for: .top, surfaceSize: surfaceSize, landmark: notch.size)
        case .leftEdge, .rightEdge:
            return EdgeRevealMotion.initialScale(for: anchor.surfaceHug, surfaceSize: surfaceSize)
        }
    }
}
