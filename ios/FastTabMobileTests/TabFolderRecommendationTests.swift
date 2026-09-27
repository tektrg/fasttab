import XCTest
@testable import FastTabMobile

final class TabBookmarkEligibilityTests: XCTestCase {
    func testToolsAndAppsAreSkipped() {
        let denied = [
            "https://app.slack.com/client/T1/C2", "https://chat.google.com/room/abc",
            "https://mail.google.com/mail/u/0/#inbox", "https://calendar.google.com/calendar/r",
            "https://meet.google.com/abc-defg-hij", "https://us02web.zoom.us/j/123",
            "https://teams.microsoft.com/l/chat", "https://discord.com/channels/1/2",
            "https://www.notion.so/team/Page-123", "https://linear.app/acme/issue/ACM-1",
            "https://acme.atlassian.net/browse/X-1", "https://docs.google.com/document/d/1/edit",
            "http://localhost:3000/dashboard", "http://192.168.1.1/admin", "https://myapp.test/page",
            "https://www.google.com/search?q=swift", "https://duckduckgo.com/?q=swift",
            "https://github.com/login", "https://example.com/", "chrome://settings"
        ]
        for url in denied {
            XCTAssertFalse(TabBookmarkEligibility.isReadLaterContent(urlString: url), url)
        }
    }

    func testArticlesAndVideosAreEligible() {
        let allowed = [
            "https://www.swiftbysundell.com/articles/swiftui-state/",
            "https://www.youtube.com/watch?v=abc",
            "https://github.com/apple/swift-evolution/blob/main/README.md",
            "https://news.ycombinator.com/item?id=1"
        ]
        for url in allowed {
            XCTAssertTrue(TabBookmarkEligibility.isReadLaterContent(urlString: url), url)
        }
    }
}

final class TabFolderVoteScorerTests: XCTestCase {
    private func bookmark(_ url: String, _ title: String = "", folder: [String]) -> ScoredBookmark {
        ScoredBookmark(title: title, url: url, browserName: "Chrome", profileName: "Default", folderPath: folder)
    }

    private let neverSimilar: (String, String) -> Bool = { _, _ in false }

    func testSameHostUnanimousGivesFullConfidence() {
        let bookmarks = [
            bookmark("https://swiftbysundell.com/a", folder: ["Swift"]),
            bookmark("https://www.swiftbysundell.com/b", folder: ["Swift"]),
            bookmark("https://other.com/c", folder: ["News"])
        ]
        let result = TabFolderVoteScorer.recommend(
            tabURL: "https://swiftbysundell.com/new", tabTitle: "", bookmarks: bookmarks, isTitleSimilar: neverSimilar)
        XCTAssertEqual(result?.folderPath, ["Swift"])
        XCTAssertEqual(result?.confidence ?? 0, 1.0, accuracy: 0.001)
    }

    func testSplitVotesFallBelowGate() {
        let bookmarks = [
            bookmark("https://medium.com/a", folder: ["Swift"]),
            bookmark("https://medium.com/b", folder: ["Design"])
        ]
        let result = TabFolderVoteScorer.recommend(
            tabURL: "https://medium.com/new", tabTitle: "", bookmarks: bookmarks, isTitleSimilar: neverSimilar)
        XCTAssertEqual(result?.confidence ?? 0, 0.5, accuracy: 0.001)
        XCTAssertLessThan(result?.confidence ?? 0, TabFolderVoteScorer.minimumConfidence)
    }

    func testTitleVotesCountAndThinEvidenceReturnsNil() {
        let similarTitles: (String, String) -> Bool = { $0.contains("SwiftUI") && $1.contains("SwiftUI") }
        let one = [bookmark("https://a.com/x", "SwiftUI tips", folder: ["Swift"])]
        XCTAssertNil(TabFolderVoteScorer.recommend(
            tabURL: "https://b.com/y", tabTitle: "SwiftUI layout", bookmarks: one, isTitleSimilar: similarTitles))

        let three = one + [
            bookmark("https://c.com/x", "SwiftUI lists", folder: ["Swift"]),
            bookmark("https://d.com/x", "SwiftUI nav", folder: ["Swift"])
        ]
        let result = TabFolderVoteScorer.recommend(
            tabURL: "https://b.com/y", tabTitle: "SwiftUI layout", bookmarks: three, isTitleSimilar: similarTitles)
        XCTAssertEqual(result?.folderName, "Swift")
    }

    func testAlreadyBookmarkedPageIsDetected() {
        let bookmarks = [bookmark("https://www.example.com/post/", folder: ["Read"])]
        XCTAssertTrue(TabFolderVoteScorer.isAlreadyBookmarked(tabURL: "https://example.com/post", bookmarks: bookmarks))
        XCTAssertFalse(TabFolderVoteScorer.isAlreadyBookmarked(tabURL: "https://example.com/other", bookmarks: bookmarks))
    }

    func testParseModelChoice() {
        XCTAssertEqual(TabFolderVoteScorer.parseModelChoice("2|0.9", folderCount: 3)?.index, 1)
        XCTAssertEqual(TabFolderVoteScorer.parseModelChoice(" 1 | 85% ", folderCount: 3)?.confidence ?? 0, 0.85, accuracy: 0.001)
        XCTAssertNil(TabFolderVoteScorer.parseModelChoice("4|0.9", folderCount: 3))
        XCTAssertNil(TabFolderVoteScorer.parseModelChoice("Swift folder", folderCount: 3))
    }
}
