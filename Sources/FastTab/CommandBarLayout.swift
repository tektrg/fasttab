import CoreGraphics
import SwiftUI
import AppKit
import CommandBarKit

/// FastTab's own sizing on top of CommandBarKit's anchor geometry: row
/// heights, chrome allowances, quick-open row caps, and the surface/canvas
/// frames derived from them.
extension CommandBarLayout {
    /// Everything in the surface other than the results list: search header,
    /// footer, inter-section spacing, and the surface's own padding. The
    /// compact (edge) allowance is larger because the footer's hints and
    /// status text wrap onto extra lines at half width.
    ///
    /// Drops 48pt with the view switcher strip: its 38pt height plus the one
    /// 10pt inter-section gap that disappears along with it.
    private static let chromeAllowance: CGFloat = 122
    private static let compactChromeAllowance: CGFloat = 152

    /// The footer's own share of `chromeAllowance` above — its content height
    /// plus the one inter-section spacing gap that disappears along with it.
    /// Subtracted when the "Show helper panel" setting is off, so the surface
    /// shrinks to fit rather than leaving the footer's reserved space empty
    /// at the bottom (`surfaceSize` is a fixed frame the content is top-aligned
    /// in — the frame doesn't shrink on its own just because a child view
    /// disappears from the VStack).
    private static let footerAllowance: CGFloat = 50
    private static let compactFooterAllowance: CGFloat = 90

    /// The gap `mainContent`'s VStack puts between every section — including
    /// above whichever view fills the footer's slot. Shared with the
    /// `compactGearRowHeight` budget below: that row is a real VStack child
    /// like the footer it replaces, so it pays this same gap, not zero.
    static let interSectionSpacing: CGFloat = 10

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

    /// Height of the compact settings row shown in place of the full
    /// `FooterShortcutBar` when the helper/footer panel is turned off —
    /// just the gear, right-aligned. A genuine layout row rather than a
    /// floating overlay: floating it over the results list meant however
    /// much of the list's own height estimate was off by (see
    /// `resultsHeight`) showed up as either the gear sitting on top of a
    /// row, or that row poking out past the panel edge underneath it. A row
    /// that actually occupies its own reserved space can't collide with
    /// whatever the list ends up rendering above it.
    static let compactGearRowHeight: CGFloat = 16

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
    static func expandedAllTabsMaxRows(for anchor: CommandBarAnchor, rowStyle: ResultRowStyle, showFooter: Bool = true) -> Int {
        let compact = isCompact(anchor)
        let perRow = rowStyle == .minimal ? minimalResultRowHeight : (compact ? compactResultRowHeight : resultRowHeight)
        var allowance = compact ? compactChromeAllowance : chromeAllowance
        if !showFooter {
            allowance -= (compact ? compactFooterAllowance : footerAllowance) - (compactGearRowHeight + interSectionSpacing)
        }
        let available = expandedAllTabsMaxHeight - allowance - surfaceTopInset(for: anchor)
        let fitting = Int((available / perRow).rounded(.down))
        return max(fitting, minQuickOpenItemLimit)
    }

    /// Single source of truth for row-cap branching across both SwiftUI view sizing (ContentView)
    /// and AppKit pointer hit testing (FastTabApp.isCursorOutsideSurface).
    /// The tall Stack view and the "show all tabs" expansion both resolve to expandedAllTabsMaxRows.
    static func surfaceMaxRows(
        view: CommandBarView,
        isShowingAllOpenTabs: Bool,
        isSearching: Bool,
        anchor: CommandBarAnchor,
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

    /// Height of the scrollable results list. `rowCount` lets the panel shrink
    /// to fit the actual number of visible rows; pass `Int.max` (the default)
    /// to always reserve the full `maxRows`-row budget. `maxRows` is the
    /// ceiling `rowCount` clamps against — defaults to the fixed live-search
    /// cap, but callers sizing the quick-open list pass its (screen-clamped)
    /// configurable limit instead.
    static func resultsHeight(for anchor: CommandBarAnchor, rowStyle: ResultRowStyle = .full, rowCount: Int = Int.max, maxRows: Int = Int(visibleResultRows)) -> CGFloat {
        let perRow = rowStyle == .minimal ? minimalResultRowHeight : (isCompact(anchor) ? compactResultRowHeight : resultRowHeight)
        let clampedCount = CGFloat(min(max(rowCount, 1), maxRows))
        return perRow * clampedCount
    }

    /// `topInset` overrides the live `surfaceTopInset(for:)` lookup — only for
    /// callers that need a pure result independent of the current display
    /// (`minimumCanvasSize(fittingScreenHeight:reservedTopInset:)`, and tests).
    static func surfaceSize(for anchor: CommandBarAnchor, rowStyle: ResultRowStyle = .full, rowCount: Int = Int.max, maxRows: Int = Int(visibleResultRows), showFooter: Bool = true, topInset: CGFloat? = nil) -> CGSize {
        let compact = isCompact(anchor)
        let width = automaticWidth(for: anchor, rowStyle: rowStyle)
        var allowance = compact ? compactChromeAllowance : chromeAllowance
        if !showFooter {
            // Shrinks from the full footer bar down to the compact gear-only
            // row's height, not to zero — that row still needs to be counted
            // in the budget (see `compactGearRowHeight`).
            allowance -= (compact ? compactFooterAllowance : footerAllowance) - (compactGearRowHeight + interSectionSpacing)
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
    /// `EdgeRevealSurfaceShape`).
    static func surfaceOffset(canvasSize: CGSize, anchor: CommandBarAnchor, rowStyle: ResultRowStyle = .full, rowCount: Int = Int.max, maxRows: Int = Int(visibleResultRows), showFooter: Bool = true) -> CGSize {
        let size = surfaceSize(for: anchor, rowStyle: rowStyle, rowCount: rowCount, maxRows: maxRows, showFooter: showFooter)
        switch anchor {
        case .notch:
            return CGSize(width: 0, height: -(canvasSize.height - size.height) / 2)
        case .leftEdge:
            return CGSize(width: -(canvasSize.width - size.width) / 2, height: 0)
        case .rightEdge:
            return CGSize(width: (canvasSize.width - size.width) / 2, height: 0)
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
        anchor: CommandBarAnchor,
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

    static func shouldDismissClick(at screenLocation: CGPoint, in canvasFrame: CGRect, anchor: CommandBarAnchor) -> Bool {
        !surfaceFrame(in: canvasFrame, anchor: anchor).contains(screenLocation)
    }
}
