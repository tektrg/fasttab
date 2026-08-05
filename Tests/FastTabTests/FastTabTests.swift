import Foundation
import AppKit
import SwiftUI
import Testing
@testable import FastTab

@Test func searchResultsSortByTypePriorityBeforeRecency() async throws {
    let now = Date()
    let history = BrowserSearchResult(
        title: "Recent history",
        url: "https://example.com/history",
        browserName: "Google Chrome",
        type: .history,
        timestamp: now
    )
    let bookmark = BrowserSearchResult(
        title: "Older bookmark",
        url: "https://example.com/bookmark",
        browserName: "Google Chrome",
        type: .bookmark,
        timestamp: now.addingTimeInterval(-60)
    )
    let tab = BrowserSearchResult(
        title: "Old tab",
        url: "https://example.com/tab",
        browserName: "Microsoft Edge",
        type: .tab,
        timestamp: now.addingTimeInterval(-120)
    )

    let sorted = sortBrowserSearchResults([history, bookmark, tab])

    #expect(sorted.map(\.type) == [.tab, .bookmark, .history])
}

@Test func searchResultsSortNewestFirstWithinSameType() async throws {
    let now = Date()
    let olderBookmark = BrowserSearchResult(
        title: "Older bookmark",
        url: "https://example.com/older",
        browserName: "Google Chrome",
        type: .bookmark,
        timestamp: now.addingTimeInterval(-300)
    )
    let newerBookmark = BrowserSearchResult(
        title: "Newer bookmark",
        url: "https://example.com/newer",
        browserName: "Google Chrome",
        type: .bookmark,
        timestamp: now
    )

    let sorted = sortBrowserSearchResults([olderBookmark, newerBookmark])

    #expect(sorted.map(\.title) == ["Newer bookmark", "Older bookmark"])
}

@Test func searchResultMatchesTitleOrURLCaseInsensitively() async throws {
    let result = BrowserSearchResult(
        title: "Command Bar Spec",
        url: "https://docs.example.com/command-bar",
        browserName: "Google Chrome",
        type: .bookmark,
        timestamp: .now
    )

    #expect(result.matches(query: "spec"))
    #expect(result.matches(query: "DOCS.EXAMPLE.COM"))
    #expect(!result.matches(query: "calendar"))
}

@Test func searchResultUsesURLWhenSourceTitleIsEmpty() async throws {
    let result = BrowserSearchResult(
        title: "  ",
        url: "https://example.com/loading",
        browserName: "Microsoft Edge",
        type: .tab,
        timestamp: .now
    )

    #expect(result.title == "https://example.com/loading")
}

@Test func searchResultStripsMediaIndicatorFromWindowNameOnly() async throws {
    let result = BrowserSearchResult(
        title: "\u{1F50A} Playing tab title",
        url: "https://example.com/audio",
        browserName: "Google Chrome",
        type: .tab,
        timestamp: .now,
        windowName: "\u{1F50A} Shared audio window"
    )

    #expect(result.title == "\u{1F50A} Playing tab title")
    #expect(result.windowName == "Shared audio window")
}

@Test func browserWindowMediaIndicatorMapsToOnlyMatchingTab() async throws {
    #expect(browserWindowMediaIndicatorBelongsToTab(
        tabTitle: "How to Claim Your Leadership Power | Michael Timms | TED - YouTube",
        windowName: "\u{1F50A} How to Claim Your Leadership P…Michael Timms | TED - YouTube"
    ))
    #expect(!browserWindowMediaIndicatorBelongsToTab(
        tabTitle: "Extensions",
        windowName: "\u{1F50A} How to Claim Your Leadership P…Michael Timms | TED - YouTube"
    ))
}

@Test func normalizedBrowserWindowNameStripsTrailingMediaIndicator() async throws {
    #expect(normalizedBrowserWindowName("Shared audio window \u{1F50A}") == "Shared audio window")
}

@Test func quickOpenVisibleTabsSkipsCurrentFlowActiveTab() async throws {
    let now = Date()
    let activeTab = BrowserSearchResult(
        title: "Active tab",
        url: "https://example.com/active",
        browserName: "Microsoft Edge",
        type: .tab,
        timestamp: now,
        isCurrentFlowActiveTab: true
    )
    let previousTab = BrowserSearchResult(
        title: "Previous tab",
        url: "https://example.com/previous",
        browserName: "Microsoft Edge",
        type: .tab,
        timestamp: now.addingTimeInterval(-10)
    )
    let olderTab = BrowserSearchResult(
        title: "Older tab",
        url: "https://example.com/older",
        browserName: "Microsoft Edge",
        type: .tab,
        timestamp: now.addingTimeInterval(-20)
    )

    let visibleTabs = quickOpenVisibleTabs(from: [activeTab, previousTab, olderTab], limit: 2)

    #expect(visibleTabs.map(\.title) == ["Previous tab", "Older tab"])
}

@Test func quickOpenDisplayStateUsesFifthSlotForShowAllTabs() async throws {
    let tabs = makeQuickOpenTabs(count: 6)

    let state = quickOpenDisplayState(from: tabs, limit: 5, isShowingAllOpenTabs: false)

    #expect(state.results.map(\.title) == ["Tab 1", "Tab 2", "Tab 3", "Tab 4"])
    #expect(state.includesShowAllTabsItem)
}

@Test func allQuickOpenTabsSortsFullLiveSnapshotByRecencyAndSkipsCurrentFlowTab() async throws {
    let now = Date()
    let activeTab = BrowserSearchResult(
        title: "Current tab",
        url: "https://example.com/current",
        browserName: "Google Chrome",
        type: .tab,
        timestamp: now,
        isCurrentFlowActiveTab: true
    )
    let olderTab = BrowserSearchResult(
        title: "Older tab",
        url: "https://example.com/older",
        browserName: "Google Chrome",
        type: .tab,
        timestamp: now.addingTimeInterval(-20)
    )
    let newerTab = BrowserSearchResult(
        title: "Newer tab",
        url: "https://example.com/newer",
        browserName: "Google Chrome",
        type: .tab,
        timestamp: now.addingTimeInterval(-5)
    )

    let tabs = allQuickOpenTabs(from: [activeTab, olderTab, newerTab])

    #expect(tabs.map(\.title) == ["Newer tab", "Older tab"])
}

@Test func quickOpenDisplayStateShowsAllTabsWhenExpanded() async throws {
    let tabs = makeQuickOpenTabs(count: 6)

    let state = quickOpenDisplayState(from: tabs, limit: 5, isShowingAllOpenTabs: true)

    #expect(state.results.map(\.title) == tabs.map(\.title))
    #expect(!state.includesShowAllTabsItem)
}

@Test func quickOpenDisplayStateDoesNotShowSentinelWhenFourOrFewerTabs() async throws {
    let tabs = makeQuickOpenTabs(count: 4)

    let state = quickOpenDisplayState(from: tabs, limit: 5, isShowingAllOpenTabs: false)

    #expect(state.results.map(\.title) == tabs.map(\.title))
    #expect(!state.includesShowAllTabsItem)
}

@Test func quickOpenDisplayStateUsesSentinelWhenExactlyFiveTabs() async throws {
    let tabs = makeQuickOpenTabs(count: 5)

    let state = quickOpenDisplayState(from: tabs, limit: 5, isShowingAllOpenTabs: false)

    #expect(state.results.map(\.title) == ["Tab 1", "Tab 2", "Tab 3", "Tab 4"])
    #expect(state.includesShowAllTabsItem)
}

@Test func quickOpenDisplayStateUsesSentinelAtMinimumConfigurableLimit() async throws {
    let tabs = makeQuickOpenTabs(count: 4)

    let state = quickOpenDisplayState(from: tabs, limit: CommandBarLayout.minQuickOpenItemLimit, isShowingAllOpenTabs: false)

    #expect(state.results.map(\.title) == ["Tab 1", "Tab 2"])
    #expect(state.includesShowAllTabsItem)
}

@Test func quickOpenDisplayStateUsesSentinelAtMaximumConfigurableLimit() async throws {
    let tabs = makeQuickOpenTabs(count: 20)

    let state = quickOpenDisplayState(from: tabs, limit: CommandBarLayout.maxQuickOpenItemLimit, isShowingAllOpenTabs: false)

    #expect(state.results.count == CommandBarLayout.maxQuickOpenItemLimit - 1)
    #expect(state.includesShowAllTabsItem)
}

@Test func tabRecencyKeyDistinguishesDuplicateURLsByTabSlot() async throws {
    let first = BrowserSearchResult(
        title: "First duplicate",
        url: "https://example.com/shared",
        browserName: "Google Chrome",
        type: .tab,
        timestamp: .now,
        windowIndex: 1,
        tabIndex: 1
    )
    let second = BrowserSearchResult(
        title: "Second duplicate",
        url: "https://example.com/shared",
        browserName: "Google Chrome",
        type: .tab,
        timestamp: .now,
        windowIndex: 2,
        tabIndex: 1
    )

    #expect(first.tabRecencyKey != second.tabRecencyKey)
    #expect(first.tabRecencyKey == makeTabRecencyKey(
        browserName: "Google Chrome",
        windowIndex: 1,
        tabIndex: 1,
        url: "https://example.com/shared"
    ))
}

private func makeQuickOpenTabs(count: Int) -> [BrowserSearchResult] {
    (1...count).map { index in
        BrowserSearchResult(
            title: "Tab \(index)",
            url: "https://example.com/\(index)",
            browserName: "Google Chrome",
            type: .tab,
            timestamp: Date(timeIntervalSince1970: TimeInterval(1_000 - index)),
            windowIndex: 1,
            tabIndex: index
        )
    }
}

@Test func commandBarCanvasExpandsToLargeDisplay() async throws {
    let displayFrame = CGRect(x: -1920, y: 0, width: 2560, height: 1440)

    let canvasFrame = CommandBarLayout.canvasFrame(for: displayFrame)

    #expect(canvasFrame == displayFrame)
}

@Test func commandBarCanvasKeepsSurfaceVisibleOnTinyDisplay() async throws {
    let displayFrame = CGRect(x: 100, y: 200, width: 500, height: 320)

    let canvasFrame = CommandBarLayout.canvasFrame(for: displayFrame)

    // The canvas floor is sized to the tallest the panel can ever get on
    // *this* screen (the quick-open row count clamped to what actually fits),
    // not the raw configurable ceiling — that unclamped max is taller than
    // most real displays' logical height, which centered the canvas (and so
    // the notch-flush panel) above the display's real top edge instead of
    // flush against it.
    #expect(canvasFrame.size == CommandBarLayout.surfaceSize(for: .notch, maxRows: CommandBarLayout.maxQuickOpenRowsFittingScreen(rowStyle: .full)))
    #expect(canvasFrame.midX == displayFrame.midX)
    #expect(canvasFrame.midY == displayFrame.midY)
}

@Test func commandBarCanvasNeverOutgrowsANotchedDisplay() async throws {
    // A 14" MacBook Pro built-in display: 1512x982 logical, 32pt physical notch.
    // The canvas floor used to budget only the chrome and rows and then add the
    // notch clearance on top, so it came out 994pt — 12pt taller than the
    // display. `canvasFrame` centers the canvas, so those 12pt split into 6pt
    // hanging off the top and bottom, clipping the panel's top edge and pushing
    // its content 6pt higher than intended under the notch.
    let notchedDisplayHeight: CGFloat = 982
    let physicalNotchHeight: CGFloat = 32

    let canvasSize = CommandBarLayout.minimumCanvasSize(
        fittingScreenHeight: notchedDisplayHeight,
        reservedTopInset: physicalNotchHeight
    )

    #expect(canvasSize.height <= notchedDisplayHeight)
    // Still generous — the fix must shrink the row budget, not collapse it.
    #expect(canvasSize.height >= CommandBarLayout.surfaceSize(
        for: .notch,
        maxRows: CommandBarLayout.minQuickOpenItemLimit,
        topInset: physicalNotchHeight
    ).height)

    // And a display with no notch keeps every row the chrome budget allows.
    let unnotched = CommandBarLayout.minimumCanvasSize(
        fittingScreenHeight: notchedDisplayHeight,
        reservedTopInset: 0
    )
    #expect(unnotched.height <= notchedDisplayHeight)
    #expect(unnotched.height > canvasSize.height)
}

@Test func maxQuickOpenRowsLeavesRoomForThePhysicalNotch() async throws {
    let withoutNotch = CommandBarLayout.maxQuickOpenRows(fittingScreenHeight: 982, rowStyle: .full)
    let withNotch = CommandBarLayout.maxQuickOpenRows(
        fittingScreenHeight: 982,
        rowStyle: .full,
        reservedTopInset: 32
    )

    #expect(withNotch < withoutNotch)
    #expect(withNotch >= CommandBarLayout.minQuickOpenItemLimit)
}

@Test func commandBarSurfaceFrameHugsTopEdgeForNotchAnchor() async throws {
    // Tall enough that the canvas equals the display itself rather than the
    // worst-case floor (now sized around the max *configurable* quick-open
    // count, not a fixed 5 rows) — otherwise there's no slack left below the
    // (also worst-case-sized) dismiss-test surface frame to assert on.
    let displayFrame = CGRect(x: 0, y: 0, width: 2560, height: 1440)

    let canvasFrame = CommandBarLayout.canvasFrame(for: displayFrame)
    let surfaceFrame = CommandBarLayout.surfaceFrame(in: canvasFrame, anchor: .notch)

    // `surfaceFrame` backs the outside-click dismiss test, which has no
    // visibility into the live row style/count — it deliberately uses the
    // max quick-open row count so an expanded panel is never dismissed by a
    // click that's still visually inside it.
    #expect(surfaceFrame.size == CommandBarLayout.surfaceSize(for: .notch, maxRows: CommandBarLayout.maxQuickOpenItemLimit))
    #expect(surfaceFrame.minX > canvasFrame.minX)
    #expect(surfaceFrame.maxX < canvasFrame.maxX)
    #expect(surfaceFrame.minY > canvasFrame.minY)
    #expect(surfaceFrame.maxY == canvasFrame.maxY) // flush against the top, by design
    #expect(!surfaceFrame.contains(CGPoint(x: canvasFrame.minX + 24, y: canvasFrame.midY)))
    #expect(surfaceFrame.contains(CGPoint(x: canvasFrame.midX, y: surfaceFrame.midY)))
    #expect(CommandBarLayout.shouldDismissClick(
        at: CGPoint(x: canvasFrame.minX + 24, y: canvasFrame.midY),
        in: canvasFrame,
        anchor: .notch
    ))
    #expect(!CommandBarLayout.shouldDismissClick(
        at: CGPoint(x: canvasFrame.midX, y: surfaceFrame.midY),
        in: canvasFrame,
        anchor: .notch
    ))
}

@Test func commandBarSurfaceFrameHugsSideEdgeForEdgeAnchors() async throws {
    let displayFrame = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    let canvasFrame = CommandBarLayout.canvasFrame(for: displayFrame)

    let leftFrame = CommandBarLayout.surfaceFrame(in: canvasFrame, anchor: .leftEdge)
    #expect(leftFrame.minX == canvasFrame.minX)
    #expect(leftFrame.maxX < canvasFrame.maxX)

    let rightFrame = CommandBarLayout.surfaceFrame(in: canvasFrame, anchor: .rightEdge)
    #expect(rightFrame.maxX == canvasFrame.maxX)
    #expect(rightFrame.minX > canvasFrame.minX)
}

@Test func commandBarAnchorFallsBackToNotchWhenOff() async throws {
    let displayFrame = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    let canvasFrame = CommandBarLayout.canvasFrame(for: displayFrame)

    #expect(
        CommandBarLayout.surfaceFrame(in: canvasFrame, anchor: .off)
            == CommandBarLayout.surfaceFrame(in: canvasFrame, anchor: .notch)
    )
}

@Test func commandBarSurfaceSizeHalvesWidthForEdgeAnchors() async throws {
    let notchSize = CommandBarLayout.surfaceSize(for: .notch)
    let leftSize = CommandBarLayout.surfaceSize(for: .leftEdge)
    let rightSize = CommandBarLayout.surfaceSize(for: .rightEdge)

    #expect(leftSize.width == notchSize.width / 2)
    #expect(rightSize.width == notchSize.width / 2)
    #expect(leftSize.height == rightSize.height)
    // Taller than the notch surface, not equal: titles wrap to two lines at
    // half width, so the same five rows need more vertical room.
    #expect(leftSize.height > notchSize.height)
}

@Test func commandBarResultsHeightFitsFiveRowsAtEitherWidth() async throws {
    // Guards the "5th item needs scrolling" regression: the results list must
    // stay tall enough for the full default quick-open list, and the surface
    // tall enough for the list plus its surrounding chrome.
    for anchor in [EdgeRevealStyle.notch, .leftEdge, .rightEdge] {
        let resultsHeight = CommandBarLayout.resultsHeight(for: anchor)
        let rowHeight = CommandBarLayout.isCompact(anchor) ? 78.0 : 56.0

        #expect(resultsHeight >= rowHeight * 5)
        #expect(CommandBarLayout.surfaceSize(for: anchor).height > resultsHeight)
    }
}

@Test func maxQuickOpenRowsShrinksToFitAShortLaptopScreen() async throws {
    // A short display should never let the quick-open ceiling push the panel
    // past its edge, but it should still floor at the minimum rather than 0.
    let rows = CommandBarLayout.maxQuickOpenRows(fittingScreenHeight: 700, rowStyle: .full)

    #expect(rows >= CommandBarLayout.minQuickOpenItemLimit)
    #expect(rows < CommandBarLayout.maxQuickOpenItemLimit)
}

@Test func maxQuickOpenRowsCapsAtTheConfiguredMaximumOnATallScreen() async throws {
    let rows = CommandBarLayout.maxQuickOpenRows(fittingScreenHeight: 4000, rowStyle: .full)

    #expect(rows == CommandBarLayout.maxQuickOpenItemLimit)
}

@Test func maxQuickOpenRowsGrowsWithScreenHeight() async throws {
    let shortScreenRows = CommandBarLayout.maxQuickOpenRows(fittingScreenHeight: 800, rowStyle: .full)
    let tallScreenRows = CommandBarLayout.maxQuickOpenRows(fittingScreenHeight: 1200, rowStyle: .full)

    #expect(tallScreenRows >= shortScreenRows)
}

@Test func commandBarReservesTopInsetOnlyForAPhysicallyNotchedDisplay() async throws {
    // Edge surfaces are vertically centered and never reach the top edge.
    #expect(CommandBarLayout.surfaceTopInset(for: .leftEdge) == 0)
    #expect(CommandBarLayout.surfaceTopInset(for: .rightEdge) == 0)

    // The notch surface does reach the top edge, so it clears a *physical*
    // notch — and only that. On a display without one (external monitor,
    // clamshell, older MacBook) the reserved band is pure empty space, since
    // the bar already draws above the menu-bar layer.
    let openingScreen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
    let isNotched = openingScreen.map { EdgeRevealGeometry.screenInfo(for: $0).hasPhysicalNotch } ?? false

    #expect((CommandBarLayout.surfaceTopInset(for: .notch) > 0) == isNotched)
}

@Test func commandBarSurfaceSilhouetteStaysFlushAndFlaresOnlyAtTheHuggedEdge() async throws {
    // The shape is handed the surface outset by the flare room on all sides
    // (`CommandBarSurface` does this with negative padding). It must draw its
    // hugged edge exactly on the surface's own edge — a shape that flared in
    // that direction too would lift the bar off the screen edge — and spend
    // the outset only sideways, on the flare.
    let flare = CommandBarLayout.surfaceJoinRadius
    #expect(flare > 0)
    #expect(flare < CommandBarLayout.surfaceCornerRadius)

    let surface = CGRect(x: 40, y: 60, width: 380, height: 300)
    let outset = surface.insetBy(dx: -flare, dy: -flare)

    let notch = CommandBarSurfaceShape(anchor: .notch).path(in: outset).boundingRect
    #expect(abs(notch.minY - surface.minY) < 0.5)
    #expect(abs(notch.maxY - surface.maxY) < 0.5)
    #expect(notch.minX < surface.minX)
    #expect(notch.maxX > surface.maxX)

    let left = CommandBarSurfaceShape(anchor: .leftEdge).path(in: outset).boundingRect
    #expect(abs(left.minX - surface.minX) < 0.5)
    #expect(abs(left.maxX - surface.maxX) < 0.5)
    #expect(left.minY < surface.minY)
    #expect(left.maxY > surface.maxY)

    let right = CommandBarSurfaceShape(anchor: .rightEdge).path(in: outset).boundingRect
    #expect(abs(right.maxX - surface.maxX) < 0.5)
    #expect(abs(right.minX - surface.minX) < 0.5)
    #expect(right.minY < surface.minY)
    #expect(right.maxY > surface.maxY)
}

@Test func commandBarRevealAxisRunsFromTheSliverToFullSizeAndPassesOvershootThrough() async throws {
    // Each axis of the reveal is its own spring, so each is driven by a plain
    // 0...1 progress. Progress past 1 is the spring settling and must reach the
    // scale unclamped — clamping it would flatten the bounce out of the reveal.
    let start: CGFloat = 0.12
    #expect(CommandBarLayout.revealAxis(from: start, progress: 0) == start)
    #expect(CommandBarLayout.revealAxis(from: start, progress: 1) == 1)
    #expect(CommandBarLayout.revealAxis(from: start, progress: 0.5) == (start + 1) / 2)
    #expect(CommandBarLayout.revealAxis(from: start, progress: 1.05) > 1)
}

@Test func commandBarRevealStartsExactlyNotchSizedForTheLiveSurface() async throws {
    // The pre-reveal sliver has to match the notch it hides behind for the
    // size the panel is *actually* rendered at. Deriving the ratio from
    // `surfaceSize(for:)`'s defaults instead made the reveal start ~1.5x off
    // for anyone on Minimal rows with the helper panel hidden.
    let openingScreen = NSScreen.containing(NSEvent.mouseLocation) ?? NSScreen.main
    guard let openingScreen else { return }
    let notch = EdgeRevealGeometry.notchZone(EdgeRevealGeometry.screenInfo(for: openingScreen))

    for (rowStyle, showFooter) in [(ResultRowStyle.minimal, false), (ResultRowStyle.full, true)] {
        let surface = CommandBarLayout.surfaceSize(for: .notch, rowStyle: rowStyle, rowCount: 5, maxRows: 5, showFooter: showFooter)
        let scale = CommandBarLayout.revealInitialScale(for: .notch, surfaceSize: surface)

        #expect(abs(surface.width * scale.width - notch.width) < 0.5)
        #expect(abs(surface.height * scale.height - notch.height) < 0.5)
    }
}

@Test func commandBarRevealContentFadeSpansOnlyTheEarlyPartOfTheGrowth() async throws {
    let opacity = CommandBarLayout.revealContentOpacity

    // The panel's very first rendered frame jumps straight to
    // `instantReactionFraction`, which is the fade's lower bound — the shell has
    // to arrive with no content painted on it at all.
    #expect(opacity(CommandBarLayout.revealContentFadeRange.lowerBound, 1) == 0)
    // Anything before that (including the pre-reveal sliver) stays transparent
    // rather than going negative.
    #expect(opacity(0, 0) == 0)

    // Fully opaque short of full size, so the spring's settle plays out on
    // solid content.
    #expect(opacity(CommandBarLayout.revealContentFadeRange.upperBound, 1) == 1)
    #expect(CommandBarLayout.revealContentFadeRange.upperBound < 1)

    // The slower axis governs: content must not be solid while one axis is
    // still barely out of the edge.
    #expect(opacity(1, CommandBarLayout.revealContentFadeRange.lowerBound) == 0)

    // Overshoot past 1 clamps instead of producing an invalid opacity.
    #expect(opacity(1.06, 1.04) == 1)

    // Monotonic across the ramp.
    let midpoint = opacity(0.7, 0.7)
    #expect(midpoint > 0 && midpoint < 1)
    #expect(opacity(0.6, 0.6) < midpoint)
    #expect(opacity(0.8, 0.8) > midpoint)
}

@Test func commandBarSurfaceTailFadeOnlyAffectsTheCollapse() async throws {
    let opacity = CommandBarLayout.revealSurfaceOpacity

    // Fully gone at the pre-reveal scale — that scale is a *notch-sized block*,
    // not zero, so without this the collapse still had a visible block on screen
    // at the instant the window was ordered out.
    #expect(opacity(0, 0) == 0)
    // Partly faded through the tail band.
    let tail = opacity(CommandBarLayout.revealSurfaceFadeCeiling / 2, 1)
    #expect(tail > 0 && tail < 1)
    // Solid from the ceiling onwards, and the reveal's first rendered frame sits
    // above it — so the panel never fades *in*, only out.
    #expect(opacity(CommandBarLayout.revealSurfaceFadeCeiling, 1) == 1)
    #expect(CommandBarLayout.revealSurfaceFadeCeiling < CommandBarLayout.revealContentFadeRange.lowerBound)
    // Overshoot past 1 clamps.
    #expect(opacity(1.06, 1.04) == 1)
}

@Test func commandBarSurfaceAlignmentMatchesTheAnchoredEdge() async throws {
    // The live bar is flushed against its edge by *alignment*, not by offsetting
    // half the measured canvas. Measuring lags the window by a layout pass, so
    // the first rendered frame after the window moved to another display drew
    // the bar inset from its edge (204pt between a 1512pt and a 1920pt-wide
    // display; dead centre on the first open after launch) before snapping
    // flush. Alignment resolves inside the same layout pass, so it cannot lag.
    #expect(CommandBarLayout.surfaceAlignment(for: .notch) == .top)
    #expect(CommandBarLayout.surfaceAlignment(for: .off) == .top)
    #expect(CommandBarLayout.surfaceAlignment(for: .leftEdge) == .leading)
    #expect(CommandBarLayout.surfaceAlignment(for: .rightEdge) == .trailing)

    // Each anchor's alignment has to agree with the side its shape leaves flat
    // and the side the reveal scales out of, or the bar would grow out of one
    // edge while sitting against another.
    for anchor in [EdgeRevealStyle.notch, .off, .leftEdge, .rightEdge] {
        let alignment = CommandBarLayout.surfaceAlignment(for: anchor)
        let unitPoint = CommandBarLayout.revealAnchorUnitPoint(for: anchor)
        if alignment == .top {
            #expect(unitPoint == .top)
        } else if alignment == .leading {
            #expect(unitPoint == .leading)
        } else {
            #expect(unitPoint == .trailing)
        }
    }
}

@Test func commandBarShadowShiftPointsAwayFromTheAnchoredEdge() async throws {
    // Down for the notch, inboard for the side anchors — the shadow is only
    // ever cast away from the edge the panel is hinged on.
    #expect(CommandBarLayout.shadowShiftVector(for: .notch) == CGSize(width: 0, height: CommandBarLayout.shadowDirectionalShift))
    #expect(CommandBarLayout.shadowShiftVector(for: .off) == CGSize(width: 0, height: CommandBarLayout.shadowDirectionalShift))
    #expect(CommandBarLayout.shadowShiftVector(for: .leftEdge) == CGSize(width: CommandBarLayout.shadowDirectionalShift, height: 0))
    #expect(CommandBarLayout.shadowShiftVector(for: .rightEdge) == CGSize(width: -CommandBarLayout.shadowDirectionalShift, height: 0))
}

@Test func duplicateURLNormalizationTrimsWhitespaceOnly() {
    #expect(BrowserTabService.normalizeDuplicateURL("  https://example.com/path  ") == "https://example.com/path")
    #expect(BrowserTabService.normalizeDuplicateURL("https://example.com/path") == "https://example.com/path")
}

@Test func duplicateURLNormalizationRequiresExactMatch() {
    // Trailing slash, casing, query params, and fragments all make URLs
    // distinct — duplicate detection is exact-match only, no fuzzing.
    #expect(BrowserTabService.normalizeDuplicateURL("https://example.com/") != BrowserTabService.normalizeDuplicateURL("https://example.com"))
    #expect(BrowserTabService.normalizeDuplicateURL("HTTPS://EXAMPLE.COM/path") != BrowserTabService.normalizeDuplicateURL("https://example.com/path"))
    #expect(BrowserTabService.normalizeDuplicateURL("https://example.com/search?q=apple") != BrowserTabService.normalizeDuplicateURL("https://example.com/search?q=banana"))
    #expect(BrowserTabService.normalizeDuplicateURL("https://example.com/page#section") != BrowserTabService.normalizeDuplicateURL("https://example.com/page"))
    #expect(BrowserTabService.normalizeDuplicateURL("https://sharepoint.com/doc?e=session1") != BrowserTabService.normalizeDuplicateURL("https://sharepoint.com/doc?e=session2"))
}

@Test func duplicateURLNormalizationHandlesFinderPaths() {
    let path = "/Users/trungluong/Desktop"
    #expect(BrowserTabService.normalizeDuplicateURL(path) == path)
}

@Test func duplicateScopeFilterDetectsTabsWithSameExactURL() {
    let now = Date()
    let chrome = "Google Chrome"
    let tabs: [BrowserSearchResult] = [
        BrowserSearchResult(title: "Tab 1", url: "https://example.com/path", browserName: chrome, type: .tab, timestamp: now, windowIndex: 1, tabIndex: 1),
        BrowserSearchResult(title: "Tab 2", url: "https://example.com/path", browserName: chrome, type: .tab, timestamp: now, windowIndex: 1, tabIndex: 2),
        BrowserSearchResult(title: "Trailing slash", url: "https://example.com/path/", browserName: chrome, type: .tab, timestamp: now, windowIndex: 1, tabIndex: 3),
        BrowserSearchResult(title: "Unique", url: "https://other.com/", browserName: chrome, type: .tab, timestamp: now, windowIndex: 1, tabIndex: 4),
    ]

    var counts: [String: Int] = [:]
    for tab in tabs where tab.type == .tab {
        let key = tab.browserName + "|" + BrowserTabService.normalizeDuplicateURL(tab.url)
        counts[key, default: 0] += 1
    }
    let duplicates = tabs.filter { (counts[$0.browserName + "|" + BrowserTabService.normalizeDuplicateURL($0.url)] ?? 0) >= 2 }

    #expect(duplicates.count == 2)
    #expect(duplicates.allSatisfy { $0.title == "Tab 1" || $0.title == "Tab 2" })
}

@Test func duplicateScopeFilterExcludesCrossBrowserMatches() {
    let now = Date()
    let url = "https://example.com/"
    let tabs: [BrowserSearchResult] = [
        BrowserSearchResult(title: "Chrome tab", url: url, browserName: "Google Chrome", type: .tab, timestamp: now),
        BrowserSearchResult(title: "Safari tab", url: url, browserName: "Safari", type: .tab, timestamp: now),
    ]

    var counts: [String: Int] = [:]
    for tab in tabs where tab.type == .tab {
        let key = tab.browserName + "|" + BrowserTabService.normalizeDuplicateURL(tab.url)
        counts[key, default: 0] += 1
    }
    let duplicates = tabs.filter { (counts[$0.browserName + "|" + BrowserTabService.normalizeDuplicateURL($0.url)] ?? 0) >= 2 }

    #expect(duplicates.isEmpty, "Cross-browser tabs should NOT be flagged as duplicates")
}

@Test func commandBarShadowRadiusStaysInsideLargeDisplaysAwayFromTheFlushEdge() async throws {
    let displayFrame = CGRect(x: -1920, y: 0, width: 2560, height: 1440)
    let canvasSize = CGSize(width: 2560, height: 1440)

    let canvasFrame = CommandBarLayout.canvasFrame(for: displayFrame)
    let backdropSize = CommandBarLayout.shadowBackdropSize(for: canvasSize)
    let offset = CommandBarLayout.surfaceOffset(canvasSize: canvasSize, anchor: .notch)
    let shadowCenter = CGPoint(x: canvasFrame.midX + offset.width, y: canvasFrame.midY + offset.height)

    // The notch anchor deliberately touches the top edge (see
    // commandBarSurfaceFrameHugsTopEdgeForNotchAnchor) — the halo is only
    // checked against the other three sides, which still have plenty of
    // room on a large display.
    let marginsAwayFromAnchor = [
        shadowCenter.x - canvasFrame.minX,
        canvasFrame.maxX - shadowCenter.x,
        canvasFrame.maxY - shadowCenter.y
    ]

    #expect(backdropSize.width == canvasSize.width + CommandBarLayout.shadowOverscan)
    #expect(backdropSize.height == canvasSize.height + CommandBarLayout.shadowOverscan)
    #expect(marginsAwayFromAnchor.allSatisfy { CommandBarLayout.shadowEndRadius < $0 })
}

@Test func trialPolicyExpiresAfterSevenDays() async throws {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let trial = TrialRecord(startedAt: start)

    #expect(TrialPolicy.access(for: trial, now: start) == .trial(daysRemaining: 7))
    #expect(TrialPolicy.access(for: trial, now: start.addingTimeInterval(6 * 24 * 60 * 60)) == .trial(daysRemaining: 1))
    #expect(TrialPolicy.access(for: trial, now: start.addingTimeInterval(7 * 24 * 60 * 60)) == .expiredTrial)
}

@Test func personalLicenseRequiresPaidUpgradeForFutureMajorVersion() async throws {
    let license = makeStoredLicense(
        tier: .personal,
        status: .granted,
        licensedMajorVersion: 1
    )

    #expect(LicenseEntitlementPolicy.access(for: license, currentMajorVersion: 2) == .paidMajorUpgradeRequired(.personal))
}

@Test func lifetimeLicenseCoversFutureMajorVersion() async throws {
    let license = makeStoredLicense(
        tier: .lifetime,
        status: .granted,
        licensedMajorVersion: Int.max
    )

    #expect(LicenseEntitlementPolicy.access(for: license, currentMajorVersion: 9) == .licensed(.lifetime))
}

@Test func revokedLicenseBlocksImmediately() async throws {
    let license = makeStoredLicense(
        tier: .lifetime,
        status: .revoked,
        licensedMajorVersion: Int.max
    )

    #expect(LicenseEntitlementPolicy.access(for: license, currentMajorVersion: 1) == .revoked)
}

@Test func paymentConfigurationMapsTierFromConfiguredBenefitIDOnly() async throws {
    let configuration = PaymentConfiguration(
        organizationID: "org",
        personalBenefitID: "personal-benefit",
        lifetimeBenefitID: "lifetime-benefit",
        teamBenefitID: "team-benefit",
        personalCheckoutURL: nil,
        lifetimeCheckoutURL: nil,
        teamCheckoutURL: nil,
        pricingURL: nil,
        manageLicenseURL: nil,
        supportURL: nil,
        currentMajorVersion: 1,
        personalLicensedMajorVersion: 1,
        apiBaseURL: URL(string: "https://api.polar.sh")!
    )

    #expect(configuration.tier(for: "team-benefit") == .team)
    #expect(configuration.tier(for: "unknown-benefit") == .unknown)
    #expect(configuration.validatesBenefitID("team-benefit"))
    #expect(!configuration.validatesBenefitID("unknown-benefit"))
}

@Test func polarLicenseKeyDecodesFractionalAndStandardDates() async throws {
    let fractionalJSON = """
    {
      "id": "license-id",
      "benefit_id": "benefit-id",
      "display_key": "****-KEY",
      "status": "granted",
      "limit_activations": 3,
      "usage": 1,
      "last_validated_at": "2024-09-02T13:57:00.977363Z"
    }
    """.data(using: .utf8)!

    let standardJSON = """
    {
      "id": "license-id",
      "benefit_id": "benefit-id",
      "display_key": "****-KEY",
      "status": "granted",
      "limit_activations": 3,
      "usage": 1,
      "last_validated_at": "2024-09-02T13:57:00Z"
    }
    """.data(using: .utf8)!

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom(PolarDateDecoder.decode)

    #expect(try decoder.decode(PolarLicenseKey.self, from: fractionalJSON).lastValidatedAt != nil)
    #expect(try decoder.decode(PolarLicenseKey.self, from: standardJSON).lastValidatedAt != nil)
}

@MainActor
@Test func licenseServiceRefreshesTrialExpiryWithoutStorageRead() async throws {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let storage = InMemoryLicenseStorage(trial: TrialRecord(startedAt: start))
    let service = LicenseService(
        configuration: testPaymentConfiguration(),
        storage: storage,
        client: NoopPolarLicenseClient()
    )

    #expect(service.snapshot.access == .trial(daysRemaining: 7))

    service.refreshTimeSensitiveState(now: start.addingTimeInterval(7 * 24 * 60 * 60))

    #expect(service.snapshot.access == .expiredTrial)
    #expect(storage.loadTrialCount == 1)
}

private func makeStoredLicense(
    tier: FastTabLicenseTier,
    status: PolarLicenseStatus,
    licensedMajorVersion: Int
) -> StoredLicense {
    StoredLicense(
        key: "license-key",
        activationID: "activation-id",
        licenseKeyID: "license-id",
        displayKey: "****-KEY",
        benefitID: "benefit-id",
        tier: tier,
        status: status,
        activationLimit: 5,
        activationUsage: 1,
        licensedMajorVersion: licensedMajorVersion,
        lastValidatedAt: Date(timeIntervalSince1970: 1_800_000_000),
        device: DeviceActivationIdentity(installID: "install-id", label: "Test Mac")
    )
}

private func testPaymentConfiguration() -> PaymentConfiguration {
    PaymentConfiguration(
        organizationID: "org",
        personalBenefitID: "personal-benefit",
        lifetimeBenefitID: "lifetime-benefit",
        teamBenefitID: "team-benefit",
        personalCheckoutURL: nil,
        lifetimeCheckoutURL: nil,
        teamCheckoutURL: nil,
        pricingURL: nil,
        manageLicenseURL: nil,
        supportURL: nil,
        currentMajorVersion: 1,
        personalLicensedMajorVersion: 1,
        apiBaseURL: URL(string: "https://api.polar.sh")!
    )
}

@MainActor
private final class InMemoryLicenseStorage: LicenseStorage {
    var trial: TrialRecord?
    var license: StoredLicense?
    var device: DeviceActivationIdentity?
    var loadTrialCount = 0

    init(trial: TrialRecord? = nil, license: StoredLicense? = nil) {
        self.trial = trial
        self.license = license
    }

    func loadTrial() throws -> TrialRecord? {
        loadTrialCount += 1
        return trial
    }

    func saveTrial(_ trial: TrialRecord) throws {
        self.trial = trial
    }

    func loadLicense() throws -> StoredLicense? {
        license
    }

    func saveLicense(_ license: StoredLicense) throws {
        self.license = license
    }

    func deleteLicense() throws {
        license = nil
    }

    func loadDeviceIdentity() throws -> DeviceActivationIdentity? {
        device
    }

    func saveDeviceIdentity(_ identity: DeviceActivationIdentity) throws {
        device = identity
    }
}

@MainActor
private struct NoopPolarLicenseClient: PolarLicenseClient {
    func activate(
        key: String,
        organizationID: String,
        label: String,
        conditions: [String: Int],
        meta: [String: String]
    ) async throws -> PolarActivationResponse {
        throw PolarLicenseClientError.invalidResponse
    }

    func validate(
        key: String,
        organizationID: String,
        activationID: String,
        conditions: [String: Int]
    ) async throws -> PolarLicenseKey {
        throw PolarLicenseClientError.invalidResponse
    }
}
