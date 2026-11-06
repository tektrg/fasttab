import Foundation
import Testing
@testable import FastTab

/// `CustomViewFilter`: AND-across / OR-within semantics, last-visit
/// resolution (incl. the bookmark→history join and unknown handling), dedupe
/// and sort order.
struct CustomViewFilterTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let hour: TimeInterval = 3_600
    static let day: TimeInterval = 86_400

    static func item(
        _ type: BrowserResultType,
        _ url: String,
        title: String = "Page",
        ago: TimeInterval? = 60,
        profile: String? = nil,
        browser: String = "Google Chrome"
    ) -> BrowserSearchResult {
        BrowserSearchResult(
            title: title,
            url: url,
            browserName: browser,
            type: type,
            timestamp: ago.map { now.addingTimeInterval(-$0) } ?? Date(timeIntervalSince1970: 0),
            windowIndex: type == .tab ? 1 : nil,
            tabIndex: type == .tab ? 1 : nil,
            bookmarkID: type == .bookmark ? UUID().uuidString : nil,
            profileName: profile
        )
    }

    private func titles(_ view: CustomView, _ candidates: [BrowserSearchResult]) -> [String] {
        CustomViewFilter.apply(view, to: candidates, now: Self.now).map(\.title)
    }

    // MARK: Field semantics

    @Test func emptyViewShowsTabsBookmarksHistoryButNotOtherKinds() {
        let candidates = [
            Self.item(.tab, "https://a.com", title: "tab"),
            Self.item(.bookmark, "https://b.com", title: "bm"),
            Self.item(.history, "https://c.com", title: "hist"),
            Self.item(.sent, "https://d.com", title: "sent"),
            Self.item(.fastTabList, "https://e.com", title: "list"),
        ]
        #expect(Set(titles(CustomView(name: "all"), candidates)) == ["tab", "bm", "hist"])
    }

    @Test func typesAreOredWithinField() {
        let candidates = [
            Self.item(.tab, "https://a.com", title: "tab"),
            Self.item(.bookmark, "https://b.com", title: "bm"),
            Self.item(.history, "https://c.com", title: "hist"),
        ]
        #expect(Set(titles(CustomView(name: "v", types: [.tab, .bookmark]), candidates)) == ["tab", "bm"])
        #expect(titles(CustomView(name: "v", types: [.history]), candidates) == ["hist"])
    }

    @Test func profilesAreCaseInsensitiveAndOred() {
        let candidates = [
            Self.item(.tab, "https://a.com/1", title: "work", profile: "Work"),
            Self.item(.tab, "https://a.com/2", title: "personal", profile: "personal"),
            Self.item(.tab, "https://a.com/3", title: "other", profile: "Other"),
            Self.item(.tab, "https://a.com/4", title: "none", profile: nil),
        ]
        let view = CustomView(name: "v", profiles: ["work", " PERSONAL "])
        #expect(Set(titles(view, candidates)) == ["work", "personal"])
    }

    @Test func domainsMatchSubdomainsAndAreOred() {
        let candidates = [
            Self.item(.tab, "https://github.com/x", title: "gh"),
            Self.item(.tab, "https://gist.github.com/y", title: "gist"),
            Self.item(.tab, "https://www.gitlab.com/z", title: "gl"),
            Self.item(.tab, "https://notgithub.com", title: "fake"),
            Self.item(.tab, "file:///Users/me/a.txt", title: "file"),
        ]
        let view = CustomView(name: "v", domains: ["https://www.GitHub.com/anything", "*.gitlab.com", "  "])
        #expect(Set(titles(view, candidates)) == ["gh", "gist", "gl"])
    }

    @Test func keywordsRequireEveryWordInTitleOrURL() {
        let candidates = [
            Self.item(.tab, "https://github.com/org/repo/pull/1", title: "Fix crash"),
            Self.item(.tab, "https://github.com/org/repo/issues/2", title: "Crash report"),
            Self.item(.tab, "https://example.com", title: "Pull Crash Résumé"),
        ]
        #expect(Set(titles(CustomView(name: "v", keywords: "pull crash"), candidates)) == ["Fix crash", "Pull Crash Résumé"])
        #expect(titles(CustomView(name: "v", keywords: "resume"), candidates) == ["Pull Crash Résumé"])
    }

    @Test func fieldsAreAndedTogether() {
        let candidates = [
            Self.item(.tab, "https://github.com/a", title: "match", profile: "Work"),
            Self.item(.tab, "https://github.com/b", title: "wrong profile", profile: "Home"),
            Self.item(.history, "https://github.com/c", title: "wrong type", profile: "Work"),
            Self.item(.tab, "https://gitlab.com/d", title: "wrong domain", profile: "Work"),
            Self.item(.tab, "https://github.com/e", title: "too old", ago: 10 * Self.day, profile: "Work"),
        ]
        let view = CustomView(
            name: "v", types: [.tab], profiles: ["work"], domains: ["github.com"],
            lastVisited: .within(7 * Self.day)
        )
        #expect(titles(view, candidates) == ["match"])
    }

    // MARK: Last visit

    @Test func unknownLastVisitMatchesNeitherTimeRule() {
        let candidates = [
            Self.item(.tab, "https://a.com/never", title: "never activated", ago: nil),
            Self.item(.tab, "https://a.com/1999", title: "pre-2000", ago: Self.now.timeIntervalSince1970 - 900_000_000),
            Self.item(.bookmark, "https://a.com/bm", title: "unvisited bookmark", ago: nil),
            Self.item(.tab, "https://a.com/recent", title: "recent", ago: Self.hour),
            Self.item(.tab, "https://a.com/old", title: "old", ago: 40 * Self.day),
        ]
        #expect(titles(CustomView(name: "v", lastVisited: .within(Self.day)), candidates) == ["recent"])
        #expect(titles(CustomView(name: "v", lastVisited: .olderThan(30 * Self.day)), candidates) == ["old"])
        #expect(titles(CustomView(name: "v"), candidates).count == 5)
    }

    @Test func withinAndOlderThanBoundaries() {
        let candidates = [
            Self.item(.history, "https://a.com/exact", title: "exactly 1h", ago: Self.hour),
            Self.item(.history, "https://a.com/past", title: "1h + 1s", ago: Self.hour + 1),
        ]
        #expect(titles(CustomView(name: "v", lastVisited: .within(Self.hour)), candidates) == ["exactly 1h"])
        #expect(titles(CustomView(name: "v", lastVisited: .olderThan(Self.hour)), candidates) == ["1h + 1s"])
    }

    @Test func bookmarkLastVisitComesFromNewestMatchingHistory() {
        let bookmark = Self.item(.bookmark, "http://www.example.com/docs/", ago: nil)
        let history = [
            Self.item(.history, "https://example.com/docs#intro", ago: 5 * Self.day, browser: "Safari"),
            Self.item(.history, "https://example.com/docs", ago: 2 * Self.day),
            Self.item(.history, "https://example.com/docs?page=2", ago: Self.hour),
        ]
        let index = CustomViewFilter.makeHistoryIndex(from: history + [bookmark])
        #expect(CustomViewFilter.lastVisit(for: bookmark, historyIndex: index) == Self.now.addingTimeInterval(-2 * Self.day))

        let lonely = Self.item(.bookmark, "https://nowhere.com", ago: nil)
        #expect(CustomViewFilter.lastVisit(for: lonely, historyIndex: index) == nil)

        // Bookmark joined via history passes a time rule; history itself is filtered out by type.
        let view = CustomView(name: "v", types: [.bookmark], lastVisited: .within(3 * Self.day))
        #expect(CustomViewFilter.evaluate(view, candidates: history + [bookmark, lonely], now: Self.now).map(\.result) == [bookmark])
    }

    @Test func tabAndHistoryUseOwnTimestamp() {
        let tab = Self.item(.tab, "https://a.com", ago: Self.hour)
        let neverTab = Self.item(.tab, "https://a.com", ago: nil)
        #expect(CustomViewFilter.lastVisit(for: tab, historyIndex: [:]) == Self.now.addingTimeInterval(-Self.hour))
        #expect(CustomViewFilter.lastVisit(for: neverTab, historyIndex: ["a.com": Self.now]) == nil)
    }

    // MARK: Dedupe

    @Test func historyDuplicatesKeepNewest() {
        let candidates = [
            Self.item(.history, "https://a.com/page", title: "older", ago: 3 * Self.day, profile: "Work"),
            Self.item(.history, "https://www.a.com/page/", title: "newest", ago: Self.hour, browser: "Safari"),
            Self.item(.history, "https://a.com/page?q=2", title: "other query", ago: 2 * Self.hour),
        ]
        #expect(titles(CustomView(name: "v"), candidates) == ["newest", "other query"])
    }

    @Test func openTabSuppressesSamePageHistoryButNotViceVersa() {
        let candidates = [
            Self.item(.history, "https://a.com/page", title: "hist", ago: 60),
            Self.item(.tab, "https://a.com/page#section", title: "tab", ago: 2 * Self.day),
            Self.item(.tab, "https://a.com/page", title: "tab twin", ago: nil),
            Self.item(.bookmark, "https://a.com/page", title: "bm", ago: nil),
        ]
        // Both tabs survive, the bookmark stays, the history row goes.
        #expect(Set(titles(CustomView(name: "v"), candidates)) == ["tab", "tab twin", "bm"])
        // When tabs are excluded by the view, the history row is kept.
        #expect(titles(CustomView(name: "v", types: [.history]), candidates) == ["hist"])
        // An open tab filtered out by time doesn't suppress the history row
        // either (the bookmark passes via its history-joined visit).
        #expect(Set(titles(CustomView(name: "v", lastVisited: .within(Self.hour)), candidates)) == ["hist", "bm"])
    }

    // MARK: Sort

    @Test func sortsByLastVisitThenUnknownThenTitle() {
        let candidates = [
            Self.item(.tab, "https://a.com/1", title: "zeta unknown", ago: nil),
            Self.item(.history, "https://a.com/2", title: "day old", ago: Self.day),
            Self.item(.tab, "https://a.com/3", title: "alpha unknown", ago: nil),
            Self.item(.tab, "https://a.com/4", title: "minute old", ago: 60),
            Self.item(.bookmark, "https://a.com/5", title: "Beta tie", ago: nil),
            Self.item(.history, "https://a.com/6", title: "hour old", ago: Self.hour),
        ]
        let items = CustomViewFilter.evaluate(CustomView(name: "v"), candidates: candidates, now: Self.now)
        #expect(items.map(\.result.title) == ["minute old", "hour old", "day old", "alpha unknown", "Beta tie", "zeta unknown"])
        #expect(items.suffix(3).allSatisfy { $0.lastVisit == nil })
    }

    @Test func handlesFiveThousandCandidatesQuickly() {
        let candidates = (0..<5_000).map { i in
            Self.item(i % 3 == 0 ? .tab : (i % 3 == 1 ? .bookmark : .history),
                      "https://site\(i % 200).com/p/\(i)", title: "Item \(i)", ago: Double(i) * 60)
        }
        let view = CustomView(name: "v", domains: ["site1.com", "site2.com"], keywords: "item", lastVisited: .within(30 * Self.day))
        let start = Date()
        let result = CustomViewFilter.evaluate(view, candidates: candidates, now: Self.now)
        #expect(!result.isEmpty)
        #expect(Date().timeIntervalSince(start) < 1.0)
    }
}
