import Foundation
import Testing
@testable import FastTab

/// Settings > Bookmarks filter: same folding and word rules as every other
/// Fast Tab search (IndieSearch via `SyncSearchQuery`).
struct BookmarkFilterTests {
    private func bookmarkRow(title: String, url: String) -> BookmarkDisplayRow {
        let item = BookmarkItem(
            id: title, title: title, url: url,
            browserName: "Chrome", profileName: "Default",
            dateAdded: nil, folderPath: "Work"
        )
        return .bookmark(item: item, depth: 1, matchingLiveTab: nil, isArmedForDelete: false, isDeleting: false)
    }

    private let folderRow = BookmarkDisplayRow.folder(
        id: "work", name: "Work", depth: 0, isExpanded: true, childCount: 2, browserName: "Chrome"
    )

    private func titles(_ rows: [BookmarkDisplayRow]) -> [String] {
        rows.compactMap { row in
            guard case .bookmark(let item, _, _, _, _) = row else { return nil }
            return item.title
        }
    }

    @Test("Unaccented query finds a Vietnamese title (đ and tones optional)")
    func foldsVietnamese() {
        let rows = [folderRow, bookmarkRow(title: "Đơn hàng mới", url: "https://shop.vn/orders"),
                    bookmarkRow(title: "Dashboard", url: "https://bi.example.com")]
        #expect(titles(BookmarkDisplayRow.filter(rows, matching: "don hang")) == ["Đơn hàng mới"])
    }

    @Test("Every word must appear in the title or URL, any order; folder rows drop out")
    func wordsAcrossTitleAndURL() {
        let rows = [folderRow, bookmarkRow(title: "Sales report", url: "https://bi.example.com/sales"),
                    bookmarkRow(title: "Orders", url: "https://shop.vn/orders")]
        #expect(titles(BookmarkDisplayRow.filter(rows, matching: "example report")) == ["Sales report"])
        #expect(titles(BookmarkDisplayRow.filter(rows, matching: "shop.vn")) == ["Orders"])
        #expect(BookmarkDisplayRow.filter(rows, matching: "nothing-here").isEmpty)
    }

    @Test("Blank query shows every row, folders included")
    func blankQueryShowsAll() {
        let rows = [folderRow, bookmarkRow(title: "Orders", url: "https://shop.vn/orders")]
        #expect(BookmarkDisplayRow.filter(rows, matching: "") == rows)
        #expect(BookmarkDisplayRow.filter(rows, matching: "   ") == rows)
    }
}
