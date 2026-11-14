import CoreGraphics
import SwiftUI
import AppKit
import IndieCommandBar

/// Fast Tab's command-bar sizes. The math lives in IndieCommandBar
/// (`CommandBarSizing`); this file only holds the numbers and keeps the old
/// `CommandBarLayout.*` names as forwards. Pinned by `CommandBarSizingPinTests`.
extension CommandBarSizing {
    static let fastTab = CommandBarSizing(
        // Header + footer + section gaps + padding (drops 48pt with the old
        // view-switcher strip); compact is larger as the footer wraps.
        frameAllowance: 122,
        compactFrameAllowance: 152,
        // Footer's share, swapped for the gear row when "Show helper panel" is off.
        footerAllowance: 50,
        compactFooterAllowance: 90,
        interSectionSpacing: 10,
        // Sized for a wrapped metadata line; compact titles wrap too.
        resultRowHeight: 66,
        compactResultRowHeight: 80,
        minimalResultRowHeight: 40,
        visibleResultRows: 5,
        compactGearRowHeight: 16,
        // No user row cap any more (the "Quick-open items" setting is gone): these
        // two only feed the shared math — the tall list's row floor, and the
        // canvas floor / outside-click box ceiling.
        minQuickOpenItemLimit: 3,
        maxQuickOpenItemLimit: 15,
        // Height ceiling of the empty-search list (every open), Stack and custom
        // views; rows past it scroll.
        expandedMaxHeight: 600
    )
}

extension CommandBarLayout {
    private static var sizing: CommandBarSizing { .fastTab }

    static var interSectionSpacing: CGFloat { sizing.interSectionSpacing }
    static var visibleResultRows: CGFloat { sizing.visibleResultRows }
    static var compactGearRowHeight: CGFloat { sizing.compactGearRowHeight }
    static var minQuickOpenItemLimit: Int { sizing.minQuickOpenItemLimit }
    static var maxQuickOpenItemLimit: Int { sizing.maxQuickOpenItemLimit }
    static var expandedAllTabsMaxHeight: CGFloat { sizing.expandedMaxHeight }

    static func maxQuickOpenRows(fittingScreenHeight screenHeight: CGFloat, rowStyle: ResultRowStyle, reservedTopInset: CGFloat = 0) -> Int {
        sizing.maxQuickOpenRows(fittingScreenHeight: screenHeight, rowStyle: rowStyle, reservedTopInset: reservedTopInset)
    }

    static var minimumCanvasSize: CGSize { sizing.minimumCanvasSize }

    static func minimumCanvasSize(fittingScreenHeight: CGFloat, reservedTopInset: CGFloat) -> CGSize {
        sizing.minimumCanvasSize(fittingScreenHeight: fittingScreenHeight, reservedTopInset: reservedTopInset)
    }

    static func expandedAllTabsMaxRows(for anchor: CommandBarAnchor, rowStyle: ResultRowStyle, showFooter: Bool = true) -> Int {
        sizing.expandedMaxRows(for: anchor, rowStyle: rowStyle, showFooter: showFooter)
    }

    /// Single source of truth for row-cap branching across both SwiftUI view sizing (ContentView)
    /// and AppKit pointer hit testing (`hoverDismissMaxRows`).
    /// Every open — shortcut or mouse — lists every tab: an empty search, Stack and the
    /// custom views are all the tall list (`expandedAllTabsMaxRows`, scrolls past it). Only a
    /// live search on Recents is the short `visibleResultRows` panel.
    static func surfaceMaxRows(
        view: CommandBarView,
        isSearching: Bool,
        anchor: CommandBarAnchor,
        rowStyle: ResultRowStyle,
        showFooter: Bool
    ) -> Int {
        if isSearching, !view.isTall {
            return Int(visibleResultRows)
        }
        return expandedAllTabsMaxRows(for: anchor, rowStyle: rowStyle, showFooter: showFooter)
    }

    /// Rows of the hover-dismiss box ("stay inside or the bar closes"). Hover-dismiss only runs
    /// on an empty search, so this is the tall list — never shorter than the drawn panel
    /// (pinned by `ShortcutOpenShowsAllTabsTests`). Reads the live appearance from `defaults`.
    static func hoverDismissMaxRows(view: CommandBarView, anchor: CommandBarAnchor, defaults: UserDefaults = .standard) -> Int {
        surfaceMaxRows(
            view: view,
            isSearching: false,
            anchor: anchor,
            rowStyle: storedRowStyle(in: defaults),
            showFooter: storedShowFooter(in: defaults)
        )
    }

    static func storedRowStyle(in defaults: UserDefaults) -> ResultRowStyle {
        ResultRowStyle(rawValue: defaults.string(forKey: CommandBarAppearance.resultRowStyleKey) ?? "") ?? .minimal
    }

    static func storedShowFooter(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: CommandBarAppearance.helperPanelVisibleKey) as? Bool ?? true
    }

    static func resultsHeight(for anchor: CommandBarAnchor, rowStyle: ResultRowStyle = .full, rowCount: Int = Int.max, maxRows: Int = Int(CommandBarSizing.fastTab.visibleResultRows)) -> CGFloat {
        sizing.resultsHeight(for: anchor, rowStyle: rowStyle, rowCount: rowCount, maxRows: maxRows)
    }

    static func surfaceSize(for anchor: CommandBarAnchor, rowStyle: ResultRowStyle = .full, rowCount: Int = Int.max, maxRows: Int = Int(CommandBarSizing.fastTab.visibleResultRows), showFooter: Bool = true, topInset: CGFloat? = nil) -> CGSize {
        sizing.surfaceSize(for: anchor, rowStyle: rowStyle, rowCount: rowCount, maxRows: maxRows, showFooter: showFooter, topInset: topInset)
    }

    static func canvasFrame(for displayFrame: CGRect) -> CGRect {
        sizing.canvasFrame(for: displayFrame)
    }

    static func surfaceOffset(canvasSize: CGSize, anchor: CommandBarAnchor, rowStyle: ResultRowStyle = .full, rowCount: Int = Int.max, maxRows: Int = Int(CommandBarSizing.fastTab.visibleResultRows), showFooter: Bool = true) -> CGSize {
        sizing.surfaceOffset(canvasSize: canvasSize, anchor: anchor, rowStyle: rowStyle, rowCount: rowCount, maxRows: maxRows, showFooter: showFooter)
    }

    /// Defaults to the largest the panel can be (the outside-click test);
    /// the hover-dismiss monitor passes `hoverDismissMaxRows`.
    static func surfaceFrame(in canvasFrame: CGRect, anchor: CommandBarAnchor, rowStyle: ResultRowStyle = .full, maxRows: Int = CommandBarSizing.fastTab.maxQuickOpenItemLimit, showFooter: Bool = true, visibleFrame: CGRect? = nil) -> CGRect {
        sizing.surfaceFrame(in: canvasFrame, anchor: anchor, rowStyle: rowStyle, maxRows: maxRows, showFooter: showFooter, visibleFrame: visibleFrame)
    }

    static func shouldDismissClick(at screenLocation: CGPoint, in canvasFrame: CGRect, anchor: CommandBarAnchor, visibleFrame: CGRect? = nil) -> Bool {
        sizing.shouldDismissClick(at: screenLocation, in: canvasFrame, anchor: anchor, visibleFrame: visibleFrame)
    }
}
