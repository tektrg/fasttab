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
