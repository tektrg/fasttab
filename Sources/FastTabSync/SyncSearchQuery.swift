import Foundation
import IndieSearch

/// What the user typed into an iOS search field, folded once and then matched
/// against many synced tabs, bookmarks and history rows.
///
/// Folding comes from IndieLibKit's `IndieSearch`, the same rules as Fast Tab
/// on the Mac and Parklet: case, accents, `đ`/`ø`/`ł` and width are optional,
/// every typed word must appear in the title or the URL (any order), and
/// punctuation inside a stored word is ignored ("ecommerce" finds "e-commerce").
public struct SyncSearchQuery {
    /// The folded words that must all be found. Empty when the query has no letters or digits.
    public let words: [String]

    public init(_ query: String) {
        words = searchWords(in: query)
    }

    /// True when every typed word appears in `title` or `url`.
    /// An empty query matches everything.
    public func matches(title: String, url: String) -> Bool {
        guard !words.isEmpty else { return true }
        return foldedKeys([foldForMatching(title), foldForMatching(url)], containAllWordsOf: words)
    }
}
