import XCTest
import FastTabSync
import IndieTags
@testable import FastTabMobile

final class HighlightFeedModelTests: XCTestCase {

    private func highlight(_ id: String, text: String, urlKey: String, tags: [String] = []) -> ReaderHighlight {
        ReaderHighlight(id: id, urlKey: urlKey, selectedText: text, color: .yellow, serializedRange: "{}", tags: tags)
    }

    private func path(_ raw: String) -> TagPath { TagPath(raw)! }

    /// a: work/ssv on article A · b: work on article B, folder Reading · c: untagged on A.
    private lazy var entries: [HighlightFeedEntry] = {
        let highlights = [
            highlight("a", text: "Quyết định nhanh hơn", urlKey: "https://a.com/1", tags: ["work/ssv"]),
            highlight("b", text: "Agents plan then act", urlKey: "https://b.com/2", tags: ["work"]),
            highlight("c", text: "Nothing tagged", urlKey: "https://a.com/1"),
        ]
        let titles = ["https://a.com/1": "Article A", "https://b.com/2": "Bài viết B"]
        let folders = ["https://b.com/2": [path("Reading/AI")]]
        return HighlightFeedModel.entries(
            from: highlights,
            articleTitle: { titles[$0.urlKey] ?? "" },
            folderTags: { folders[$0.urlKey] ?? [] }
        )
    }()

    private func visibleIDs(_ filter: HighlightFeedFilter = HighlightFeedFilter(), search: String = "") -> [String] {
        HighlightFeedModel.visibleEntries(entries, filter: filter, searchText: search).map(\.id)
    }

    func testNoFilterKeepsOrder() {
        XCTAssertEqual(visibleIDs(), ["a", "b", "c"])
    }

    func testParentTagMatchesDescendants() {
        var filter = HighlightFeedFilter()
        filter.tagFilter.toggle(path("work"))
        XCTAssertEqual(visibleIDs(filter), ["a", "b"])
    }

    func testSelectedTagsAndTogether() {
        var filter = HighlightFeedFilter()
        filter.tagFilter.toggle(path("work"))
        filter.tagFilter.toggle(path("reading"))
        XCTAssertEqual(visibleIDs(filter), ["b"])
    }

    func testTappingCoveredChipDeselects() {
        var filter = HighlightFeedFilter()
        filter.tagFilter.toggleCovering(path("work"))
        filter.tagFilter.toggleCovering(path("work/ssv")) // covered by `work` → turns `work` off
        XCTAssertFalse(filter.isActive)
    }

    func testArticleFilterAndsWithTags() {
        var filter = HighlightFeedFilter()
        filter.toggleArticle(urlKey: "https://a.com/1", title: "Article A")
        XCTAssertEqual(visibleIDs(filter), ["a", "c"])
        filter.tagFilter.toggle(path("work"))
        XCTAssertEqual(visibleIDs(filter), ["a"])
        filter.toggleArticle(urlKey: "https://a.com/1", title: "Article A")
        XCTAssertNil(filter.article)
        filter.clear()
        XCTAssertFalse(filter.isActive)
    }

    func testFolderTagsFilterLikeUserTags() {
        var filter = HighlightFeedFilter()
        filter.tagFilter.toggle(path("reading"))
        XCTAssertEqual(visibleIDs(filter), ["b"])
    }

    func testSearchMatchesTextTitleAndTagsIgnoringCaseAndAccents() {
        XCTAssertEqual(visibleIDs(search: "quyet dinh"), ["a"])   // highlight text, accents folded
        XCTAssertEqual(visibleIDs(search: "bai viet"), ["b"])     // article title
        XCTAssertEqual(visibleIDs(search: "SSV"), ["a"])          // nested tag segment
        XCTAssertEqual(visibleIDs(search: "ai agents"), ["b"])    // words across folder tag + text
        XCTAssertEqual(visibleIDs(search: "zzz"), [])
    }

    func testFolderTagEqualToUserTagIsShownOnce() {
        let entry = HighlightFeedEntry(
            highlight: highlight("x", text: "t", urlKey: "k", tags: ["Reading"]),
            articleTitle: "T",
            folderTags: [path("reading"), path("Inbox")]
        )
        XCTAssertEqual(entry.userTags.map(\.displayPath), ["Reading"])
        XCTAssertEqual(entry.folderTags.map(\.displayPath), ["Inbox"])
    }

    func testKnownTagsAndSuggestions() {
        let known = HighlightFeedModel.knownTags(in: entries)
        XCTAssertEqual(known.map(\.displayPath), ["work/ssv", "work", "Reading/AI"])
        let suggestions = HighlightFeedModel.tagSuggestions(query: "wor", knownTags: known, excluding: [path("work")])
        XCTAssertEqual(suggestions.map(\.displayPath), ["work/ssv"])
    }

    func testFolderTagsDerivedFromBookmarksByReaderKey() {
        let blob = SyncedBookmarkBlob(
            deviceID: "mac", browserName: "Chrome", profileName: "Default",
            bookmarks: [
                SyncedBookmarkItem(id: "1", title: "A", url: "https://A.com/1?utm_source=x#top", folderPath: "Work / SSV"),
                SyncedBookmarkItem(id: "2", title: "A again", url: "https://a.com/1", folderPath: "work/ssv"),
                SyncedBookmarkItem(id: "3", title: "No folder", url: "https://c.com", folderPath: nil),
            ]
        )
        let tagsByKey = HighlightFolderTags.tagsByArticleKey(from: [blob])
        let key = URL(string: "https://a.com/1")!.readerCanonicalKey
        XCTAssertEqual(tagsByKey[key]?.map(\.displayPath), ["Work/SSV"])
        XCTAssertNil(tagsByKey[URL(string: "https://c.com")!.readerCanonicalKey])
    }
}
