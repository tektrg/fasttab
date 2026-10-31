import XCTest
@testable import FastTabMobile

/// The "End of Article" footer names what Delete will remove and where the link lives.
final class ReaderEndActionsTests: XCTestCase {
    func testDeleteLabelNamesTheOnlyPlaceTheLinkLives() {
        XCTAssertEqual(ReaderEndActions(inBookmarks: true, inOpenTabs: false, inList: false).deleteLabel, "Delete Bookmark")
        XCTAssertEqual(ReaderEndActions(inBookmarks: false, inOpenTabs: true, inList: false).deleteLabel, "Close Tab")
        XCTAssertEqual(ReaderEndActions(inBookmarks: false, inOpenTabs: false, inList: true).deleteLabel, "Delete from List")
        XCTAssertEqual(ReaderEndActions(inBookmarks: true, inOpenTabs: true, inList: false).deleteLabel, "Delete Link")
        XCTAssertEqual(ReaderEndActions(inBookmarks: false, inOpenTabs: false, inList: false).deleteLabel, "Delete Link")
    }

    func testBadgesListEveryPlaceInAFixedOrder() {
        XCTAssertEqual(ReaderEndActions(inBookmarks: true, inOpenTabs: true, inList: true).badges, ["Bookmarks", "Open Tab", "FastTab List"])
        XCTAssertEqual(ReaderEndActions(inBookmarks: false, inOpenTabs: true, inList: false).badges, ["Open Tab"])
        XCTAssertEqual(ReaderEndActions(inBookmarks: false, inOpenTabs: false, inList: false).badges, [])
    }
}
