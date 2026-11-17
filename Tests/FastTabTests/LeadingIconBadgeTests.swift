import Foundation
import Testing
@testable import FastTab

/// The small circle at the bottom-right of a result row's site icon
/// (owner decisions 2026-11-17): bookmark/history rows show a grey bookmark /
/// clock instead of the browser logo; open tabs keep the browser logo; rows
/// without a site icon get the source badge on the browser logo.
@MainActor
struct LeadingIconBadgeTests {
    private func badge(_ type: BrowserResultType?, favicon: Bool, browserIcon: Bool = true) -> LeadingIconBadge {
        LeadingIconBadge.resolve(sourceType: type, hasFavicon: favicon, hasBrowserIcon: browserIcon)
    }

    @Test func openTabKeepsTheBrowserLogo() {
        #expect(badge(.tab, favicon: true) == .browser)
    }

    @Test func bookmarkAndHistoryShowTheirSourceInsteadOfTheBrowser() {
        #expect(badge(.bookmark, favicon: true) == .bookmark)
        #expect(badge(.history, favicon: true) == .history)
    }

    @Test func noSiteIconBookmarkOrHistoryGetsTheSourceBadgeOnTheBrowserLogo() {
        #expect(badge(.bookmark, favicon: false) == .bookmark)
        #expect(badge(.history, favicon: false) == .history)
    }

    /// No site icon and no browser icon: the main icon is already the type's
    /// own symbol (bookmark / clock), so a badge would repeat it.
    @Test func noIconAtAllShowsNoBadge() {
        #expect(badge(.bookmark, favicon: false, browserIcon: false) == .none)
        #expect(badge(.history, favicon: false, browserIcon: false) == .none)
    }

    @Test func otherRowsAreUnchanged() {
        #expect(badge(.tab, favicon: false) == .none)
        #expect(badge(.sent, favicon: true) == .browser)
        #expect(badge(.fastTabList, favicon: true) == .browser)
        #expect(badge(.fastTabList, favicon: false) == .none)
        // Stack rows and other callers that don't pass a source type.
        #expect(badge(nil, favicon: true) == .browser)
        #expect(badge(nil, favicon: false) == .none)
    }

    @Test func sourceBadgesUseTheApprovedSymbols() {
        #expect(LeadingIconBadge.bookmark.symbolName == "bookmark.fill")
        #expect(LeadingIconBadge.history.symbolName == "clock.fill")
        #expect(LeadingIconBadge.browser.symbolName == nil)
        #expect(LeadingIconBadge.none.symbolName == nil)
    }

    /// A page that is open AND bookmarked (AND in history) collapses into one
    /// row, the open tab, which keeps the browser logo.
    @Test func openAndBookmarkedPageShowsOneRowWithTheBrowserLogo() throws {
        let url = "https://sentinel.example/$(echo INJECTED)"
        let title = "$(echo INJECTED)"
        let rows = [
            CustomViewFilterTests.item(.bookmark, url, title: title, ago: 10),
            CustomViewFilterTests.item(.history, url, title: title, ago: 5),
            CustomViewFilterTests.item(.tab, url, title: title, ago: 600),
        ]
        let merged = deduplicatingSamePages(rows, frecencyScore: { _ in 0 })
        #expect(merged.count == 1)
        let row = try #require(merged.first)
        #expect(row.type == .tab)
        // Sentinel title stays literal text, never evaluated.
        #expect(row.title == "$(echo INJECTED)")
        #expect(badge(row.type, favicon: true) == .browser)
    }

    /// Bookmark + history twins (no open tab) keep the bookmark badge.
    @Test func bookmarkAndHistoryTwinShowsTheBookmarkBadge() {
        let url = "https://sentinel.example/page"
        let rows = [
            CustomViewFilterTests.item(.history, url, title: "Twin", ago: 5),
            CustomViewFilterTests.item(.bookmark, url, title: "Twin", ago: 600),
        ]
        let merged = deduplicatingSamePages(rows, frecencyScore: { _ in 0 })
        #expect(merged.map(\.type) == [.bookmark])
        #expect(badge(merged[0].type, favicon: true) == .bookmark)
    }
}
