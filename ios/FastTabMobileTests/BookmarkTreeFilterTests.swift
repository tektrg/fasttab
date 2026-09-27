import XCTest
import FastTabSync
@testable import FastTabMobile

/// Bookmarks tab filter: same folding and word rules as the other iOS search
/// screens (IndieSearch via `SyncSearchQuery`), applied down the folder tree.
final class BookmarkTreeFilterTests: XCTestCase {
    /// Work/
    ///   Orders/  -> "Đơn hàng mới" (shop.vn), "Invoices" (shop.vn/invoices)
    ///   "Sales report" (bi.example.com)
    /// Personal/ -> "Recipes" (food.example.org)
    private let tree = BookmarkTreeBuilder.buildTree(from: [
        SyncedBookmarkBlob(deviceID: "mac", browserName: "Chrome", profileName: "Default", bookmarks: [
            SyncedBookmarkItem(id: "1", title: "Đơn hàng mới", url: "https://shop.vn/orders", folderPath: "Work/Orders"),
            SyncedBookmarkItem(id: "2", title: "Invoices", url: "https://shop.vn/invoices", folderPath: "Work/Orders"),
            SyncedBookmarkItem(id: "3", title: "Sales report", url: "https://bi.example.com", folderPath: "Work"),
            SyncedBookmarkItem(id: "4", title: "Recipes", url: "https://food.example.org", folderPath: "Personal")
        ])
    ])

    private func outline(_ nodes: [BookmarkTreeNode]) -> [String] {
        nodes.flatMap { node -> [String] in
            let line = node.isFolder ? "\(node.title)/ (\(node.totalCount))" : node.title
            return [line] + outline(node.children ?? []).map { "  " + $0 }
        }
    }

    func testUnaccentedQueryFindsVietnameseTitleAndKeepsItsFolders() {
        XCTAssertEqual(outline(BookmarkTreeBuilder.filter(tree, matching: "don hang")), [
            "Work/ (1)",
            "  Orders/ (1)",
            "    Đơn hàng mới"
        ])
    }

    func testFolderWhoseNameMatchesKeepsAllItsChildren() {
        XCTAssertEqual(outline(BookmarkTreeBuilder.filter(tree, matching: "PERSONAL")), [
            "Personal/ (1)",
            "  Recipes"
        ])
    }

    /// A matching folder that also has matching children shows only those children.
    func testMatchingChildrenNarrowAMatchingFolder() {
        XCTAssertEqual(outline(BookmarkTreeBuilder.filter(tree, matching: "orders")), [
            "Work/ (1)",
            "  Orders/ (1)",
            "    Đơn hàng mới"
        ])
    }

    func testWordsMayComeFromTitleAndURLInAnyOrder() {
        XCTAssertEqual(outline(BookmarkTreeBuilder.filter(tree, matching: "example report")), [
            "Work/ (1)",
            "  Sales report"
        ])
        XCTAssertTrue(BookmarkTreeBuilder.filter(tree, matching: "nothing-here").isEmpty)
    }

    func testBlankQueryReturnsTheWholeTree() {
        XCTAssertEqual(outline(BookmarkTreeBuilder.filter(tree, matching: "  ")), outline(tree))
    }
}
