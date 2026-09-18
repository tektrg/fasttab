import CoreGraphics
import SwiftUI
import AppKit
import CommandBarKit

enum CommandBarLayout {
    static let surfaceWidth: CGFloat = 640
    /// Half-width sliver for the left/right edge anchors.
    static let edgeSurfaceWidth: CGFloat = surfaceWidth / 2
    static let surfaceCornerRadius: CGFloat = 24

    /// Radius of the flare where the bar meets the screen edge it hugs — the
    /// same detail the MacBook notch uses where it meets the bezel. Small on
    /// purpose: at much more than this it stops reading as a moulded join and
    /// starts reading as two ears on the bar. See `CommandBarSurfaceShape`.
    static let surfaceJoinRadius: CGFloat = 12
    static let defaultCanvasSize = CGSize(width: 1600, height: 1000)
    static let shadowOverscan: CGFloat = 900
    static let shadowEndRadius: CGFloat = 520

    /// Minimal row style narrows the notch/off panel to this fraction of
    /// `surfaceWidth` by default — icon+title rows need far less width than
    /// the full metadata layout.
    static let minimalWidthFraction: CGFloat = 2.0 / 3.0

    /// Vertical allowance for the view switcher strip (Recents / My Order / Bookmarks).
    static let viewSwitcherAllowance: CGFloat = 38

    /// Everything in the surface other than the results list: search header,
    /// view switcher strip, footer, inter-section spacing, and the surface's
    /// own padding. The compact (edge) allowance is larger because the footer's
    /// hints and status text wrap onto extra lines at half width.
    private static let chromeAllowance: CGFloat = 170
    private static let compactChromeAllowance: CGFloat = 200

    /// The footer's own share of `chromeAllowance` above — its content height
    /// plus the one inter-section spacing gap that disappears along with it.
    /// Subtracted when the "Show helper panel" setting is off, so the surface
    /// shrinks to fit rather than leaving the footer's reserved space empty
    /// at the bottom (`surfaceSize` is a fixed frame the content is top-aligned
    /// in — the frame doesn't shrink on its own just because a child view
    /// disappears from the VStack).
    private static let footerAllowance: CGFloat = 50
    private static let compactFooterAllowance: CGFloat = 90

    /// One results row, including the spacing below it. Sized for the common
    /// case where the metadata line wraps (long URLs push onto a third line),
    /// not just the bare title + single metadata line. Compact rows are taller
    /// still because titles also wrap to two lines at half width.
    private static let resultRowHeight: CGFloat = 66
    private static let compactResultRowHeight: CGFloat = 80

    /// Minimal rows are a single title line with no wrapping metadata, so they
    /// stay this short regardless of anchor.
    private static let minimalResultRowHeight: CGFloat = 40

    /// Rows the live-search results list shows without scrolling. Unrelated to
    /// the user-configurable quick-open item count (see `minQuickOpenItemLimit`
    /// below) — search results keep this fixed ceiling regardless of that
    /// setting. Also the default height ceiling used when sizing around actual
    /// row count.
    static let visibleResultRows: CGFloat = 5

    /// Stepper bounds for the quick-open ("recent tabs") item-count setting.
    static let minQuickOpenItemLimit = 3
    static let maxQuickOpenItemLimit = 15

    /// How many rows of `rowStyle` fit within `screenHeight` without the panel
    /// growing past the screen edge. Pure/testable — the live variant below
    /// feeds it the real screen height. Floors at `minQuickOpenItemLimit` (a
    /// screen too short even for that is treated as "show the minimum" rather
    /// than zero) and never exceeds `maxQuickOpenItemLimit`.
    ///
    /// `reservedTopInset` is the physical-notch clearance `surfaceSize` adds on
    /// top of the chrome and rows (see `surfaceTopInset`). It has to be
    /// subtracted here too: budgeting only `chromeAllowance` made the "fitting"
    /// row count too generous by that inset, so the panel it described was
    /// taller than the screen it was supposed to fit inside — 994pt on a 982pt
    /// built-in display.
    static func maxQuickOpenRows(
        fittingScreenHeight screenHeight: CGFloat,
        rowStyle: ResultRowStyle,
        reservedTopInset: CGFloat = 0
    ) -> Int {
        let perRow = rowStyle == .minimal ? minimalResultRowHeight : resultRowHeight
        let available = screenHeight - chromeAllowance - reservedTopInset
        let fitting = Int((available / perRow).rounded(.down))
        return min(max(fitting, minQuickOpenItemLimit), maxQuickOpenItemLimit)
    }

    /// Live-screen variant of `maxQuickOpenRows(fittingScreenHeight:rowStyle:)`
    /// — falls back to the full ceiling when no screen is resolvable (headless
    /// test environments, or between display changes) rather than under-showing.
    static func maxQuickOpenRowsFittingScreen(rowStyle: ResultRowStyle) -> Int {
        guard let screen = notchClearanceScreen else { return maxQuickOpenItemLimit }
        return maxQuickOpenRows(
            fittingScreenHeight: screen.frame.height,
            rowStyle: rowStyle,
            reservedTopInset: surfaceTopInset(for: .notch)
        )
    }

    /// Always the tallest a panel can be (full row style, max possible
    /// quick-open row count *that actually fits this screen*) — a safe floor
    /// for the invisible canvas window so an expanded quick-open panel is
    /// never clipped.
    ///
    /// Uses the screen-clamped ceiling, not the raw `maxQuickOpenItemLimit`:
    /// the unclamped max (170 + 66×15 ≈ 1160pt, plus the physical notch) is
    /// taller than most MacBook built-in displays' logical height. Since
    /// `canvasFrame` centers the canvas on the display and this floor forced
    /// the canvas taller than the display itself, the notch-flush panel's
    /// top — the search field — ended up centered above the display's real
    /// top edge instead of flush against it, invisible off-screen.
    static var minimumCanvasSize: CGSize {
        minimumCanvasSize(
            // No resolvable screen (headless tests, mid display change) keeps
            // the old behaviour of the full ceiling rather than under-sizing.
            fittingScreenHeight: notchClearanceScreen?.frame.height ?? .greatestFiniteMagnitude,
            reservedTopInset: surfaceTopInset(for: .notch)
        )
    }

    /// Pure/testable counterpart to `minimumCanvasSize` — the floor for a
    /// display of `fittingScreenHeight` whose physical-notch clearance is
    /// `reservedTopInset`. Never taller than `fittingScreenHeight` for any real
    /// display height (only a display too short for even
    /// `minQuickOpenItemLimit` rows can exceed it, and then by design: the
    /// surface stays whole rather than being cropped).
    static func minimumCanvasSize(fittingScreenHeight: CGFloat, reservedTopInset: CGFloat) -> CGSize {
        surfaceSize(
            for: .notch,
            maxRows: maxQuickOpenRows(
                fittingScreenHeight: fittingScreenHeight,
                rowStyle: .full,
                reservedTopInset: reservedTopInset
            ),
            topInset: reservedTopInset
        )
    }

    /// Height ceiling for the panel once "Show all tabs" expands the
    /// quick-open list past its default row cap. Kept independent of the
    /// screen-fit ceiling `maxQuickOpenRowsFittingScreen` uses for the
    /// default (collapsed) list — that one scales with display height and on
    /// a tall display would let the expanded list grow to fill most of the
    /// screen. Rows beyond this ceiling scroll inside the fixed-height panel
    /// instead (the results list is already a `ScrollView`).
    static let expandedAllTabsMaxHeight: CGFloat = 600

    /// Row-count ceiling that keeps the panel within `expandedAllTabsMaxHeight`
    /// for the given anchor/row style — the `maxRows` used once "Show all
    /// tabs" is expanded, in place of the screen-fit quick-open limit.
    static func expandedAllTabsMaxRows(for anchor: EdgeRevealStyle, rowStyle: ResultRowStyle, showFooter: Bool = true) -> Int {
        let compact = isCompact(anchor)
        let perRow = rowStyle == .minimal ? minimalResultRowHeight : (compact ? compactResultRowHeight : resultRowHeight)
        var allowance = compact ? compactChromeAllowance : chromeAllowance
        if !showFooter {
            allowance -= compact ? compactFooterAllowance : footerAllowance
        }
        let available = expandedAllTabsMaxHeight - allowance - surfaceTopInset(for: anchor)
        let fitting = Int((available / perRow).rounded(.down))
        return max(fitting, minQuickOpenItemLimit)
    }

    /// Single source of truth for row-cap branching across both SwiftUI view sizing (ContentView)
    /// and AppKit pointer hit testing (FastTabApp.isCursorOutsideSurface).
    /// Tall views (My Order & Bookmarks) and the "show all tabs" expansion both resolve to expandedAllTabsMaxRows.
    static func surfaceMaxRows(
        view: CommandBarView,
        isShowingAllOpenTabs: Bool,
        isSearching: Bool,
        anchor: EdgeRevealStyle,
        rowStyle: ResultRowStyle,
        showFooter: Bool,
        quickOpenLimit: Int
    ) -> Int {
        if view.isTall || isShowingAllOpenTabs {
            return expandedAllTabsMaxRows(for: anchor, rowStyle: rowStyle, showFooter: showFooter)
        }
        if isSearching {
            return Int(visibleResultRows)
        }
        return min(max(quickOpenLimit, minQuickOpenItemLimit), maxQuickOpenItemLimit)
    }

    /// Single source of truth for whether the command bar has an active search in progress.
    /// Non-empty when the text field has content, when scope chips (e.g. @Finder) are attached,
    /// or when a search engine alias (e.g. [Jira]) is active.
    static func isSearchActive(
        searchText: String,
        hasScopeChips: Bool = false,
        hasActiveAlias: Bool = false
    ) -> Bool {
        !searchText.isEmpty || hasScopeChips || hasActiveAlias
    }

    /// True only when the search field is completely blank, no scope chips exist,
    /// and no search engine alias is active. Only when empty may the bar auto-collapse on hover exit.
    static func isSearchEmpty(
        searchText: String,
        hasScopeChips: Bool = false,
        hasActiveAlias: Bool = false
    ) -> Bool {
        !isSearchActive(searchText: searchText, hasScopeChips: hasScopeChips, hasActiveAlias: hasActiveAlias)
    }

    /// Default dwell time before an untouched bar auto-collapses on hover exit.
    static let defaultHoverDismissDwell: TimeInterval = 0.35

    /// Grace delay before hover-dismiss can collapse the bar after typing activity.
    /// When the user deletes their query down to empty, gives them time to
    /// think and type their next query without the bar yanking away mid-thought.
    static let defaultTypingDismissDelay: TimeInterval = 2.0

    /// Calculates how long to wait before hover-dismiss fires based on recent typing activity.
    /// If the user was recently typing, extends the delay up to `typingDelay`.
    /// For an untouched bar (or long-stale typing), returns `hoverDwell`.
    static func hoverDismissDelay(
        lastTypingDate: Date?,
        now: Date = Date(),
        typingDelay: TimeInterval = defaultTypingDismissDelay,
        hoverDwell: TimeInterval = defaultHoverDismissDwell
    ) -> TimeInterval {
        if let lastTypingDate {
            let elapsed = max(0, now.timeIntervalSince(lastTypingDate))
            if elapsed < typingDelay {
                return max(hoverDwell, typingDelay - elapsed)
            }
        }
        return hoverDwell
    }

    static func isCompact(_ anchor: EdgeRevealStyle) -> Bool {
        switch anchor {
        case .off, .notch:            return false
        case .leftEdge, .rightEdge:   return true
        }
    }

    /// The panel width before any manual drag override — full width in Full
    /// row style, narrowed for Minimal, unaffected for the fixed-width edge
    /// anchors.
    static func automaticWidth(for anchor: EdgeRevealStyle, rowStyle: ResultRowStyle) -> CGFloat {
        guard !isCompact(anchor) else { return edgeSurfaceWidth }
        return rowStyle == .minimal ? surfaceWidth * minimalWidthFraction : surfaceWidth
    }

    /// Height of the scrollable results list. `rowCount` lets the panel shrink
    /// to fit the actual number of visible rows; pass `Int.max` (the default)
    /// to always reserve the full `maxRows`-row budget. `maxRows` is the
    /// ceiling `rowCount` clamps against — defaults to the fixed live-search
    /// cap, but callers sizing the quick-open list pass its (screen-clamped)
    /// configurable limit instead.
    static func resultsHeight(for anchor: EdgeRevealStyle, rowStyle: ResultRowStyle = .full, rowCount: Int = Int.max, maxRows: Int = Int(visibleResultRows)) -> CGFloat {
        let perRow = rowStyle == .minimal ? minimalResultRowHeight : (isCompact(anchor) ? compactResultRowHeight : resultRowHeight)
        let clampedCount = CGFloat(min(max(rowCount, 1), maxRows))
        return perRow * clampedCount
    }

    /// `topInset` overrides the live `surfaceTopInset(for:)` lookup — only for
    /// callers that need a pure result independent of the current display
    /// (`minimumCanvasSize(fittingScreenHeight:reservedTopInset:)`, and tests).
    static func surfaceSize(for anchor: EdgeRevealStyle, rowStyle: ResultRowStyle = .full, rowCount: Int = Int.max, maxRows: Int = Int(visibleResultRows), showFooter: Bool = true, topInset: CGFloat? = nil) -> CGSize {
        let compact = isCompact(anchor)
        let width = automaticWidth(for: anchor, rowStyle: rowStyle)
        var allowance = compact ? compactChromeAllowance : chromeAllowance
        if !showFooter {
            allowance -= compact ? compactFooterAllowance : footerAllowance
        }
        return CGSize(
            width: width,
            // The notch anchor sits flush against the top of the display, so
            // the physical notch (or the menu bar) would otherwise sit on top
            // of the search field — the surface grows by that much and pads
            // its content down to clear it (see `surfaceTopInset`).
            height: allowance
                + resultsHeight(for: anchor, rowStyle: rowStyle, rowCount: rowCount, maxRows: maxRows)
                + (topInset ?? surfaceTopInset(for: anchor))
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

    /// Width of the real physical notch, for the small black connector drawn
    /// in the clearance inset above (see `ContentView`) — kept notch-width,
    /// not the full (much wider) panel width, so it reads as the notch
    /// extending down a little rather than a wide black bar across the top.
    /// Zero under the same conditions as `surfaceTopInset` (nothing to draw).
    static func notchConnectorWidth(for anchor: EdgeRevealStyle) -> CGFloat {
        guard !isCompact(anchor) else { return 0 }
        guard let screen = notchClearanceScreen else { return 0 }
        let info = EdgeRevealGeometry.screenInfo(for: screen)
        guard info.hasPhysicalNotch else { return 0 }
        return EdgeRevealGeometry.notchZone(info).width
    }

    /// The display the notch-anchored bar will open on — the one under the
    /// pointer, matching `preferredCommandBarDisplay(preferMouseScreen:)`. Using
    /// `NSScreen.main` alone reserved (or skipped) notch clearance based on
    /// whichever display had keyboard focus, which is the wrong one whenever the
    /// bar opens on the other display of a two-display setup.
    private static var notchClearanceScreen: NSScreen? {
        NSScreen.containing(NSEvent.mouseLocation) ?? NSScreen.main
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
    /// `CommandBarSurfaceShape`).
    static func surfaceOffset(canvasSize: CGSize, anchor: EdgeRevealStyle, rowStyle: ResultRowStyle = .full, rowCount: Int = Int.max, maxRows: Int = Int(visibleResultRows), showFooter: Bool = true) -> CGSize {
        let size = surfaceSize(for: anchor, rowStyle: rowStyle, rowCount: rowCount, maxRows: maxRows, showFooter: showFooter)
        switch anchor {
        case .off, .notch:
            return CGSize(width: 0, height: -(canvasSize.height - size.height) / 2)
        case .leftEdge:
            return CGSize(width: -(canvasSize.width - size.width) / 2, height: 0)
        case .rightEdge:
            return CGSize(width: (canvasSize.width - size.width) / 2, height: 0)
        }
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
    /// so the near edge fully hides — see the offline render in
    /// scratchpad geomtest/test6.swift used to pick it.
    static let shadowDirectionalShift: CGFloat = 40

    /// Blur radius for the ambient shadow. Kept fairly tight (vs. a wide,
    /// soft cloud) so the shadow reads as a dense contact shadow hugging the
    /// panel's far edge rather than a diffuse haze — paired with
    /// `shadowDirectionalShift` above.
    static let shadowBlurRadius: CGFloat = 30

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
    static func shadowShiftVector(for anchor: EdgeRevealStyle) -> CGSize {
        switch anchor {
        case .off, .notch:
            return CGSize(width: 0, height: shadowDirectionalShift)
        case .leftEdge:
            return CGSize(width: shadowDirectionalShift, height: 0)
        case .rightEdge:
            return CGSize(width: -shadowDirectionalShift, height: 0)
        }
    }

    /// Bounding frame for the surface at some assumed row cap. Defaults to the
    /// largest the panel could ever be (full row style, max possible
    /// quick-open row count) — the outside-click dismiss test uses exactly
    /// this default, since it has no visibility into the live row style/count
    /// and an expanded quick-open panel must never be mistaken for "outside"
    /// while it's still visually on screen.
    ///
    /// The hover-dismiss monitor (`CommandBarPanelController`) instead passes
    /// the user's *actual configured* row cap: unlike a click, which could
    /// land on a panel already expanded to the global ceiling, hover-dismiss
    /// only fires while the search field is empty, when the row count can
    /// never exceed the user's own quick-open limit — using the global
    /// ceiling there left a box tall enough to swallow most of the screen's
    /// vertical middle, so leaving the bar by moving straight up or down
    /// never registered as "outside."
    static func surfaceFrame(
        in canvasFrame: CGRect,
        anchor: EdgeRevealStyle,
        rowStyle: ResultRowStyle = .full,
        maxRows: Int = maxQuickOpenItemLimit,
        showFooter: Bool = true
    ) -> CGRect {
        let size = surfaceSize(for: anchor, rowStyle: rowStyle, maxRows: maxRows, showFooter: showFooter)
        let offset = surfaceOffset(canvasSize: canvasFrame.size, anchor: anchor, rowStyle: rowStyle, maxRows: maxRows, showFooter: showFooter)
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
    static func surfaceAlignment(for anchor: EdgeRevealStyle) -> Alignment {
        switch anchor {
        case .off, .notch:
            return .top
        case .leftEdge:
            return .leading
        case .rightEdge:
            return .trailing
        }
    }

    /// One axis of the reveal: `progress` 0 leaves the axis at its pre-reveal
    /// sliver fraction, 1 lands it at full size, past 1 overshoots. Each axis
    /// gets its own spring, so each gets its own progress (see
    /// `ContentView.playRevealAnimation`).
    static func revealAxis(from start: CGFloat, progress: Double) -> CGFloat {
        start + (1 - start) * progress
    }

    /// Spring kinematics for the reveal animation when emerging from the notch or screen edge.
    /// Tuned for a fast, responsive entrance with tactile overshoot (~5-7%) and a quick damped settle (~260-280ms).
    static let revealDepthSpring: Animation = .spring(response: 0.28, dampingFraction: 0.74)
    static let revealSpreadSpring: Animation = .spring(response: 0.32, dampingFraction: 0.78)

    /// Progress at which the content starts fading in, and the one at which it
    /// is fully opaque.
    /// The upper bound is short of 1 so the fade finishes while the panel is
    /// still growing, leaving the spring's settle to play out on already-solid
    /// content rather than on something still resolving.
    static let revealContentFadeRange: ClosedRange<Double> = 0.35...0.85

    /// Content opacity for a given reveal progress. Applied to what's *inside*
    /// the surface only, never the surface's own background: fading the whole
    /// panel would make the desktop show through it mid-reveal, which reads as
    /// a rendering glitch rather than an entrance. The fade also covers for the
    /// fact that the reveal scales the panel — text is squashed at small
    /// scales, and this keeps that distortion under the fade instead of on
    /// display.
    ///
    /// Takes the *lower* of the two axis progresses so the content only reaches
    /// full opacity once both axes have essentially arrived, and clamps at 1 so
    /// the spring's overshoot past 1 can't push it into an invalid opacity.
    static func revealContentOpacity(depthProgress: Double, spreadProgress: Double) -> Double {
        let progress = min(depthProgress, spreadProgress)
        let range = revealContentFadeRange
        let span = range.upperBound - range.lowerBound
        return min(max((progress - range.lowerBound) / span, 0), 1)
    }

    /// Progress below which the surface itself (background included, not just
    /// its content) starts fading out.
    static let revealSurfaceFadeCeiling: Double = 0.25

    /// Opacity of the whole surface — the shell, not just what's inside it (see
    /// `revealContentOpacity` for that). Exists to soften the end of the
    /// collapse: the pre-reveal scale is a *notch-sized block*, not zero, so a
    /// collapse that only shrank would still have a visible block on screen at
    /// the instant the window is ordered out, which reads as the bar being
    /// snatched away. Fading the last stretch lets it dissolve into the bezel
    /// instead.
    ///
    /// Safe to fade the background here (unlike during the reveal) precisely
    /// because it only happens at the tail, where the panel is already down to
    /// notch/sliver size and flush against the edge — there's no large
    /// translucent slab for the desktop to show through.
    static func revealSurfaceOpacity(depthProgress: Double, spreadProgress: Double) -> Double {
        let progress = min(depthProgress, spreadProgress)
        return min(max(progress / revealSurfaceFadeCeiling, 0), 1)
    }

    /// SwiftUI anchor the grow-from-edge reveal animation scales around —
    /// matches whichever side `CommandBarSurfaceShape` leaves flat.
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

    /// Starting (pre-animation) scale for the grow-from-edge reveal. Edge
    /// reveals have no physical landmark to match, so they keep a fixed thin
    /// sliver. The notch reveal instead matches the real notch's (or its fake
    /// stand-in's) exact width and height, so the animation starts perfectly
    /// hidden behind it rather than an arbitrarily-sized sliver that reads as
    /// wider than the notch and hanging below it.
    ///
    /// `surfaceSize` must be the *live* size the panel is actually rendered at.
    /// Deriving it from `surfaceSize(for:)`'s defaults instead (full row style,
    /// footer shown, five rows) made the ratio wrong by however much the user's
    /// real settings differ — with Minimal rows and the helper panel off the
    /// notch reveal started ~1.5x smaller than the notch in both axes, and any
    /// taller-than-default panel would have started *larger* than the notch,
    /// hanging visibly below it before the animation began.
    static func revealInitialScale(for anchor: EdgeRevealStyle, surfaceSize: CGSize) -> CGSize {
        switch anchor {
        case .off, .notch:
            guard let screen = notchClearanceScreen, surfaceSize.width > 0, surfaceSize.height > 0 else {
                return CGSize(width: 0.35, height: 0.12)
            }
            let notch = EdgeRevealGeometry.notchZone(EdgeRevealGeometry.screenInfo(for: screen))
            return CGSize(
                width: max(0.02, min(1, notch.width / surfaceSize.width)),
                height: max(0.02, min(1, notch.height / surfaceSize.height))
            )
        case .leftEdge, .rightEdge:
            return CGSize(width: 0.12, height: 0.35)
        }
    }
}
