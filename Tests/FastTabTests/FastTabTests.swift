import Foundation
import AppKit
import SwiftUI
import Testing
@testable import FastTab
import CommandBarKit

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

@Test func quickOpenVisibleTabsIncludesCurrentFlowActiveTab() async throws {
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

    #expect(visibleTabs.map(\.title) == ["Active tab", "Previous tab"])
}

@Test func quickOpenDisplayStateUsesFifthSlotForShowAllTabs() async throws {
    let tabs = makeQuickOpenTabs(count: 6)

    let state = quickOpenDisplayState(from: tabs, limit: 5, isShowingAllOpenTabs: false)

    #expect(state.results.map(\.title) == ["Tab 1", "Tab 2", "Tab 3", "Tab 4"])
    #expect(state.includesShowAllTabsItem)
}

@Test func allQuickOpenTabsSortsFullLiveSnapshotByRecencyAndIncludesCurrentFlowTab() async throws {
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

    #expect(tabs.map(\.title) == ["Current tab", "Newer tab", "Older tab"])
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

@Test func mouseOpenSetsAllTabsWhileShortcutCapsAtQuickOpenLimit() async throws {
    // Shortcut trigger caps at quick open limit with "Show all tabs..." sentinel
    let shortcutTrigger = CommandBarOpenTrigger.shortcut
    #expect(!shortcutTrigger.isMouse)
    #expect(!shortcutTrigger.shouldExpandAllTabs)

    let tabs = makeQuickOpenTabs(count: 8)
    let shortcutDisplayState = quickOpenDisplayState(
        from: tabs,
        limit: 5,
        isShowingAllOpenTabs: shortcutTrigger.shouldExpandAllTabs
    )
    #expect(shortcutDisplayState.results.count == 4)
    #expect(shortcutDisplayState.includesShowAllTabsItem)

    // Mouse trigger expands to show all tabs immediately
    let mouseTrigger = CommandBarOpenTrigger.mouse
    #expect(mouseTrigger.isMouse)
    #expect(mouseTrigger.shouldExpandAllTabs)

    let mouseDisplayState = quickOpenDisplayState(
        from: tabs,
        limit: 5,
        isShowingAllOpenTabs: mouseTrigger.shouldExpandAllTabs
    )
    #expect(mouseDisplayState.results.count == 8)
    #expect(!mouseDisplayState.includesShowAllTabsItem)
}

@Test func openTriggerContextPreservedAcrossViewSwitchAndSearchClear() async throws {
    let tabs = makeQuickOpenTabs(count: 8)

    // 1. Mouse open flow:
    // When opened by mouse, wasOpenedByMouse is true, isShowingAllOpenTabs starts true.
    let mouseWasOpenedByMouse = CommandBarOpenTrigger.mouse.isMouse
    var mouseIsShowingAllOpenTabs = CommandBarOpenTrigger.mouse.shouldExpandAllTabs
    #expect(mouseWasOpenedByMouse)
    #expect(mouseIsShowingAllOpenTabs)

    // Switching views resets isShowingAllOpenTabs to wasOpenedByMouse
    mouseIsShowingAllOpenTabs = mouseWasOpenedByMouse
    var displayState = quickOpenDisplayState(from: tabs, limit: 5, isShowingAllOpenTabs: mouseIsShowingAllOpenTabs)
    #expect(displayState.results.count == 8)
    #expect(!displayState.includesShowAllTabsItem)

    // Typing search sets isShowingAllOpenTabs to false
    mouseIsShowingAllOpenTabs = false
    // Clearing search restores isShowingAllOpenTabs = true because wasOpenedByMouse is true
    if mouseWasOpenedByMouse {
        mouseIsShowingAllOpenTabs = true
    }
    displayState = quickOpenDisplayState(from: tabs, limit: 5, isShowingAllOpenTabs: mouseIsShowingAllOpenTabs)
    #expect(displayState.results.count == 8)
    #expect(!displayState.includesShowAllTabsItem)

    // 2. Shortcut open flow:
    // When opened by shortcut, wasOpenedByMouse is false, isShowingAllOpenTabs starts false.
    let shortcutWasOpenedByMouse = CommandBarOpenTrigger.shortcut.isMouse
    var shortcutIsShowingAllOpenTabs = CommandBarOpenTrigger.shortcut.shouldExpandAllTabs
    #expect(!shortcutWasOpenedByMouse)
    #expect(!shortcutIsShowingAllOpenTabs)

    // Switching views resets isShowingAllOpenTabs to wasOpenedByMouse (false)
    shortcutIsShowingAllOpenTabs = shortcutWasOpenedByMouse
    displayState = quickOpenDisplayState(from: tabs, limit: 5, isShowingAllOpenTabs: shortcutIsShowingAllOpenTabs)
    #expect(displayState.results.count == 4)
    #expect(displayState.includesShowAllTabsItem)

    // Typing search sets isShowingAllOpenTabs to false
    shortcutIsShowingAllOpenTabs = false
    // Clearing search keeps isShowingAllOpenTabs = false because wasOpenedByMouse is false
    if shortcutWasOpenedByMouse {
        shortcutIsShowingAllOpenTabs = true
    }
    displayState = quickOpenDisplayState(from: tabs, limit: 5, isShowingAllOpenTabs: shortcutIsShowingAllOpenTabs)
    #expect(displayState.results.count == 4)
    #expect(displayState.includesShowAllTabsItem)
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

@Test func expandedAllTabsSurfaceCoversHeaderAndFooterThatQuickOpenBoxMissed() async throws {
    // Regression: hover-dismiss used to bound the cursor against a box sized
    // for the quick-open list even when a hover reveal had expanded the panel
    // to show all tabs. On an edge anchor the taller expanded panel is
    // vertically centred, so its search header (top) and helper bar (bottom)
    // stuck out past that box — moving the cursor into either collapsed the
    // bar. A hover reveal always expands, so the box must be the expanded one.
    let displayFrame = CGRect(x: 0, y: 0, width: 2560, height: 1440)
    let canvasFrame = CommandBarLayout.canvasFrame(for: displayFrame)

    let expandedMaxRows = CommandBarLayout.expandedAllTabsMaxRows(for: .leftEdge, rowStyle: .minimal, showFooter: true)
    let quickOpenMaxRows = CommandBarLayout.minQuickOpenItemLimit

    #expect(expandedMaxRows > quickOpenMaxRows)

    let expanded = CommandBarLayout.surfaceFrame(in: canvasFrame, anchor: .leftEdge, rowStyle: .minimal, maxRows: expandedMaxRows, showFooter: true)
    let quickOpen = CommandBarLayout.surfaceFrame(in: canvasFrame, anchor: .leftEdge, rowStyle: .minimal, maxRows: quickOpenMaxRows, showFooter: true)

    #expect(expanded.height > quickOpen.height)

    // Search header: top strip of the expanded panel.
    let headerPoint = CGPoint(x: expanded.midX, y: expanded.maxY - 8)
    #expect(expanded.contains(headerPoint))
    #expect(!quickOpen.contains(headerPoint))

    // Helper bar: bottom strip of the expanded panel.
    let footerPoint = CGPoint(x: expanded.midX, y: expanded.minY + 8)
    #expect(expanded.contains(footerPoint))
    #expect(!quickOpen.contains(footerPoint))

    // Notch anchor: both boxes are top-flush, so it's the helper bar at the
    // bottom that the taller expanded panel pushes past the quick-open box.
    let expandedNotch = CommandBarLayout.surfaceFrame(in: canvasFrame, anchor: .notch, rowStyle: .minimal, maxRows: expandedMaxRows, showFooter: true)
    let quickOpenNotch = CommandBarLayout.surfaceFrame(in: canvasFrame, anchor: .notch, rowStyle: .minimal, maxRows: quickOpenMaxRows, showFooter: true)
    #expect(expandedNotch.height > quickOpenNotch.height)
    #expect(expandedNotch.maxY == quickOpenNotch.maxY) // both flush to the top
    let notchFooterPoint = CGPoint(x: expandedNotch.midX, y: expandedNotch.minY + 8)
    #expect(expandedNotch.contains(notchFooterPoint))
    #expect(!quickOpenNotch.contains(notchFooterPoint))
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
    let service = LicenseService(configuration: testPaymentConfiguration(), storage: storage, client: TestPolarLicenseClient())
    for _ in 0..<50 {
        if service.snapshot.trial != nil { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(service.snapshot.access == .trial(daysRemaining: 7))
    service.refreshTimeSensitiveState(now: start.addingTimeInterval(7 * 24 * 60 * 60))
    #expect(service.snapshot.access == .expiredTrial)
    #expect(await storage.loadTrialCount == 1)
}

@MainActor
@Test func licenseServiceDoesNotBlockStartupWhenStorageStalls() async throws {
    let storage = InMemoryLicenseStorage(loadDelay: .milliseconds(200))
    let clock = ContinuousClock()
    let startedAt = clock.now
    let service = LicenseService(configuration: testPaymentConfiguration(), storage: storage, client: TestPolarLicenseClient(), initialLoadTimeout: .milliseconds(20))
    #expect(clock.now - startedAt < .milliseconds(100))
    for _ in 0..<50 {
        if service.snapshot.lastErrorMessage != nil { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(service.snapshot.lastErrorMessage == "License storage is unavailable.")
    #expect(await storage.saveTrialCount == 0)
}

@MainActor
@Test func licenseServiceRecoversWhenInitialStorageLoadFinishesAfterTimeout() async throws {
    let trial = TrialRecord(startedAt: Date(timeIntervalSince1970: 1_800_000_000))
    let storedLicense = makeStoredLicense(
        tier: .personal,
        status: .granted,
        licensedMajorVersion: 1
    )
    let storage = InMemoryLicenseStorage(
        trial: trial,
        license: storedLicense,
        loadDelay: .milliseconds(150)
    )
    let service = LicenseService(
        configuration: testPaymentConfiguration(),
        storage: storage,
        client: TestPolarLicenseClient(),
        initialLoadTimeout: .milliseconds(20)
    )

    for _ in 0..<50 {
        if service.snapshot.lastErrorMessage != nil { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(service.snapshot.lastErrorMessage == "License storage is unavailable.")

    for _ in 0..<50 {
        if service.snapshot.access == .licensed(.personal) { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(service.snapshot.access == .licensed(.personal))
    #expect(service.snapshot.trial == trial)
    #expect(service.snapshot.license == storedLicense)
    #expect(service.snapshot.lastErrorMessage == nil)
}

@MainActor
@Test func staleInitialLoadCannotReplaceNewerLicenseState() async throws {
    let polarLicense = makePolarLicense()
    let storage = InMemoryLicenseStorage(loadDelay: .milliseconds(80))
    let client = TestPolarLicenseClient(
        validatedLicense: polarLicense,
        activationResponse: PolarActivationResponse(id: "activation-id", licenseKeyID: "license-id", label: "Test Mac", licenseKey: polarLicense)
    )
    let service = LicenseService(configuration: testPaymentConfiguration(), storage: storage, client: client, initialLoadTimeout: .seconds(1))
    await service.activateLicense(key: "new-license-key")
    try await Task.sleep(for: .milliseconds(120))
    #expect(service.snapshot.license?.key == "new-license-key")
    #expect(await storage.saveTrialCount == 0)
}
@MainActor
@Test func failedStorageReadDoesNotCreateTrial() async throws {
    let storage = InMemoryLicenseStorage(loadFails: true)
    let service = LicenseService(configuration: testPaymentConfiguration(), storage: storage, client: TestPolarLicenseClient())
    try await Task.sleep(for: .milliseconds(20))
    #expect(service.snapshot.lastErrorMessage == "License storage is unavailable.")
    #expect(await storage.saveTrialCount == 0)
}
@MainActor
@Test func launchValidationReplaysOnceAfterDelayedLicenseLoad() async throws {
    let storedLicense = makeStoredLicense(tier: .personal, status: .granted, licensedMajorVersion: 1, lastValidatedAt: .distantPast)
    let storage = InMemoryLicenseStorage(license: storedLicense, loadDelay: .milliseconds(80))
    let client = TestPolarLicenseClient(validatedLicense: makePolarLicense())
    let service = LicenseService(configuration: testPaymentConfiguration(), storage: storage, client: client)
    service.validateForLaunch()
    service.validateForLaunch()
    for _ in 0..<50 {
        if client.validationCount == 1 { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(client.validationCount == 1)
}
@MainActor
@Test func clearedLicenseCannotBeRecreatedByLateRevalidation() async throws {
    let stored = makeStoredLicense(tier: .personal, status: .granted, licensedMajorVersion: 1, lastValidatedAt: .distantPast)
    let validated = PolarLicenseKey(id: "license-id", benefitID: "personal-benefit", displayKey: "****-KEY", status: .granted, limitActivations: 5, usage: 1, lastValidatedAt: Date())
    let storage = InMemoryLicenseStorage(license: stored)
    let service = LicenseService(configuration: testPaymentConfiguration(), storage: storage, client: TestPolarLicenseClient(validatedLicense: validated, validationDelay: .milliseconds(80)))
    try await Task.sleep(for: .milliseconds(20))
    service.validateCachedLicenseIfNeeded(force: true)
    try await Task.sleep(for: .milliseconds(10))
    service.clearLicense()
    try await Task.sleep(for: .milliseconds(120))
    #expect(await storage.license == nil)
}
@MainActor
@Test func lateClearCannotDeleteNewerActivatedLicense() async throws {
    let polar = PolarLicenseKey(id: "new-id", benefitID: "personal-benefit", displayKey: "****-NEW", status: .granted, limitActivations: 5, usage: 1, lastValidatedAt: Date())
    let response = PolarActivationResponse(id: "new-activation", licenseKeyID: "new-id", label: "Test Mac", licenseKey: polar)
    let storage = InMemoryLicenseStorage(license: makeStoredLicense(tier: .personal, status: .granted, licensedMajorVersion: 1), deleteDelay: .milliseconds(80))
    let service = LicenseService(configuration: testPaymentConfiguration(), storage: storage, client: TestPolarLicenseClient(validatedLicense: polar, activationResponse: response))
    try await Task.sleep(for: .milliseconds(20))
    service.clearLicense()
    try await Task.sleep(for: .milliseconds(10))
    await service.activateLicense(key: "new-key")
    try await Task.sleep(for: .milliseconds(100))
    #expect(await storage.license?.key == "new-key")
}
@MainActor
@Test func ordinaryActivationPersistsLicense() async throws {
    let polar = makePolarLicense()
    let storage = InMemoryLicenseStorage()
    let client = TestPolarLicenseClient(validatedLicense: polar, activationResponse: PolarActivationResponse(id: "activation", licenseKeyID: polar.id, label: "Mac", licenseKey: polar))
    let service = LicenseService(configuration: testPaymentConfiguration(), storage: storage, client: client)
    await service.activateLicense(key: "ordinary-key")
    #expect(await storage.license?.key == "ordinary-key")
}
@MainActor
@Test func ordinaryRevalidationPersistsUpdatedLicense() async throws {
    let stored = makeStoredLicense(tier: .personal, status: .granted, licensedMajorVersion: 1, lastValidatedAt: .distantPast)
    let storage = InMemoryLicenseStorage(license: stored)
    let service = LicenseService(configuration: testPaymentConfiguration(), storage: storage, client: TestPolarLicenseClient(validatedLicense: makePolarLicense()))
    for _ in 0..<50 {
        if service.snapshot.license != nil { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    service.validateCachedLicenseIfNeeded(force: true)
    for _ in 0..<50 {
        if await storage.license?.lastValidatedAt != .distantPast { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await storage.license?.lastValidatedAt != .distantPast)
}
private func makePolarLicense() -> PolarLicenseKey {
    PolarLicenseKey(id: "license-id", benefitID: "personal-benefit", displayKey: "****-KEY", status: .granted, limitActivations: 5, usage: 1, lastValidatedAt: Date())
}
private func makeStoredLicense(tier: FastTabLicenseTier, status: PolarLicenseStatus, licensedMajorVersion: Int, lastValidatedAt: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> StoredLicense {
    StoredLicense(
        key: "license-key", activationID: "activation-id", licenseKeyID: "license-id",
        displayKey: "****-KEY", benefitID: "benefit-id", tier: tier, status: status,
        activationLimit: 5, activationUsage: 1, licensedMajorVersion: licensedMajorVersion,
        lastValidatedAt: lastValidatedAt,
        device: DeviceActivationIdentity(installID: "install-id", label: "Test Mac")
    )
}
private func testPaymentConfiguration() -> PaymentConfiguration {
    PaymentConfiguration(
        organizationID: "org", personalBenefitID: "personal-benefit",
        lifetimeBenefitID: "lifetime-benefit", teamBenefitID: "team-benefit",
        personalCheckoutURL: nil, lifetimeCheckoutURL: nil, teamCheckoutURL: nil,
        pricingURL: nil, manageLicenseURL: nil, supportURL: nil,
        currentMajorVersion: 1, personalLicensedMajorVersion: 1,
        apiBaseURL: URL(string: "https://api.polar.sh")!
    )
}

private actor InMemoryLicenseStorage: LicenseStorage {
    var trial: TrialRecord?
    var license: StoredLicense?
    var device: DeviceActivationIdentity?
    var loadTrialCount = 0
    var saveTrialCount = 0
    let loadDelay: Duration?
    let loadFails: Bool
    let deleteDelay: Duration?
    init(trial: TrialRecord? = nil, license: StoredLicense? = nil, loadDelay: Duration? = nil, loadFails: Bool = false, deleteDelay: Duration? = nil) {
        self.trial = trial
        self.license = license
        self.loadDelay = loadDelay
        self.loadFails = loadFails
        self.deleteDelay = deleteDelay
    }
    func loadTrial() throws -> TrialRecord? {
        loadTrialCount += 1
        if loadFails { throw PolarLicenseClientError.invalidResponse }
        if let loadDelay {
            Thread.sleep(forTimeInterval: TimeInterval(loadDelay.components.seconds) + Double(loadDelay.components.attoseconds) / 1e18)
        }
        return trial
    }
    func saveTrial(_ trial: TrialRecord) throws { saveTrialCount += 1; self.trial = trial }
    func loadLicense() throws -> StoredLicense? { license }
    func saveLicense(_ license: StoredLicense) throws { self.license = license }
    func deleteLicense() async throws {
        if let deleteDelay { try await Task.sleep(for: deleteDelay) }
        license = nil
    }
    func loadDeviceIdentity() throws -> DeviceActivationIdentity? { device }
    func saveDeviceIdentity(_ identity: DeviceActivationIdentity) throws { device = identity }
}
@MainActor
private final class TestPolarLicenseClient: PolarLicenseClient {
    private let validatedLicense: PolarLicenseKey?
    private let activationResponse: PolarActivationResponse?
    private let validationDelay: Duration?
    private(set) var validationCount = 0
    init(validatedLicense: PolarLicenseKey? = nil, activationResponse: PolarActivationResponse? = nil, validationDelay: Duration? = nil) {
        self.validatedLicense = validatedLicense
        self.activationResponse = activationResponse
        self.validationDelay = validationDelay
    }
    func activate(key: String, organizationID: String, label: String, conditions: [String: Int], meta: [String: String]) async throws -> PolarActivationResponse {
        guard let activationResponse else { throw PolarLicenseClientError.invalidResponse }
        return activationResponse
    }
    func validate(key: String, organizationID: String, activationID: String, conditions: [String: Int]) async throws -> PolarLicenseKey {
        validationCount += 1
        if let validationDelay { try await Task.sleep(for: validationDelay) }
        guard let validatedLicense else { throw PolarLicenseClientError.invalidResponse }
        return validatedLicense
    }
}
