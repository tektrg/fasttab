import Foundation
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

@Test func commandBarCanvasExpandsToLargeDisplay() async throws {
    let displayFrame = CGRect(x: -1920, y: 0, width: 2560, height: 1440)

    let canvasFrame = CommandBarLayout.canvasFrame(for: displayFrame)

    #expect(canvasFrame == displayFrame)
}

@Test func commandBarCanvasKeepsSurfaceVisibleOnTinyDisplay() async throws {
    let displayFrame = CGRect(x: 100, y: 200, width: 500, height: 320)

    let canvasFrame = CommandBarLayout.canvasFrame(for: displayFrame)

    #expect(canvasFrame.size == CommandBarLayout.surfaceSize)
    #expect(canvasFrame.midX == displayFrame.midX)
    #expect(canvasFrame.midY == displayFrame.midY)
}

@Test func commandBarShadowBackdropOverscansCanvas() async throws {
    let canvasSize = CGSize(width: 2560, height: 1440)

    let backdropSize = CommandBarLayout.shadowBackdropSize(for: canvasSize)

    #expect(backdropSize.width == canvasSize.width + CommandBarLayout.shadowOverscan)
    #expect(backdropSize.height == canvasSize.height + CommandBarLayout.shadowOverscan)
}
