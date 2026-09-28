import Foundation
import IndieSearch
import IndieTags

/// One highlight as the Highlights feed shows it: the highlight, its resolved article
/// title, the tags the user put on it, and the tags derived from its bookmark folder.
public struct HighlightFeedEntry: Identifiable, Hashable {
    public let highlight: ReaderHighlight
    public let articleTitle: String
    public let userTags: [TagPath]
    /// From the bookmark folder(s) of the highlight's article; never stored, so they follow
    /// the bookmarks. A folder tag equal to a user tag is dropped (the user tag shows).
    public let folderTags: [TagPath]

    public var id: String { highlight.id }

    public init(highlight: ReaderHighlight, articleTitle: String, folderTags: [TagPath]) {
        self.highlight = highlight
        self.articleTitle = articleTitle
        let userTags = highlight.tags.compactMap(TagPath.init)
        let userPaths = Set(userTags.map(\.normalizedPath))
        self.userTags = userTags
        self.folderTags = folderTags.filter { !userPaths.contains($0.normalizedPath) }
    }

    /// User tags then folder tags: what the tag filter and search look at.
    public var allTags: [TagPath] { userTags + folderTags }
}

/// The article the feed is narrowed to. Articles are not tags, so this sits beside `TagFilter`.
public struct HighlightArticleSelection: Hashable {
    public let urlKey: String
    public let title: String
}

/// Everything narrowing the feed except the search text: selected tags (AND, a parent covers
/// its descendants) and at most one article.
public struct HighlightFeedFilter: Hashable {
    public var tagFilter = TagFilter()
    public var article: HighlightArticleSelection?

    public init(tagFilter: TagFilter = TagFilter(), article: HighlightArticleSelection? = nil) {
        self.tagFilter = tagFilter
        self.article = article
    }

    public var isActive: Bool { tagFilter.isActive || article != nil }

    /// Tap on a row's article chip: selects that article, or deselects it when selected.
    public mutating func toggleArticle(urlKey: String, title: String) {
        article = article?.urlKey == urlKey ? nil : HighlightArticleSelection(urlKey: urlKey, title: title)
    }

    public func isArticleSelected(_ urlKey: String) -> Bool { article?.urlKey == urlKey }

    public func matches(_ entry: HighlightFeedEntry) -> Bool {
        if let article, article.urlKey != entry.highlight.urlKey { return false }
        return tagFilter.matches(entry.allTags)
    }

    public mutating func clear() {
        tagFilter.clear()
        article = nil
    }
}

/// Pure feed logic for `HighlightsListView`: building entries, filtering, searching, and
/// the tag suggestions for the tag editor. No UI, no stores.
public enum HighlightFeedModel {
    /// Entries in the given order (the store hands highlights over newest first).
    public static func entries(
        from highlightsNewestFirst: [ReaderHighlight],
        articleTitle: (ReaderHighlight) -> String,
        folderTags: (ReaderHighlight) -> [TagPath]
    ) -> [HighlightFeedEntry] {
        highlightsNewestFirst.map {
            HighlightFeedEntry(highlight: $0, articleTitle: articleTitle($0), folderTags: folderTags($0))
        }
    }

    /// Entries passing `filter` whose text, article title or tag names contain every word of
    /// `searchText` (any order, ignoring case, accents and punctuation). Order is kept.
    public static func visibleEntries(
        _ entries: [HighlightFeedEntry],
        filter: HighlightFeedFilter,
        searchText: String
    ) -> [HighlightFeedEntry] {
        // Fold the query once, not per entry (IndieSearch's guidance for many candidates).
        let queryWords = searchWords(in: searchText)
        return entries.filter { entry in
            filter.matches(entry) && foldedKeys(searchKeys(for: entry), containAllWordsOf: queryWords)
        }
    }

    /// Every tag in the feed, user tags first, each once (compared normalized), for the tag
    /// editor's suggestions. `TagSearch.ranked` orders them against what is typed.
    public static func knownTags(in entries: [HighlightFeedEntry]) -> [TagPath] {
        var seenPaths = Set<String>()
        let userTags = entries.flatMap(\.userTags)
        let folderTags = entries.flatMap(\.folderTags)
        return (userTags + folderTags).filter { seenPaths.insert($0.normalizedPath).inserted }
    }

    /// Suggestions for the tag editor: known tags matching `query`, closest first, minus the
    /// ones the highlight already has.
    public static func tagSuggestions(
        query: String,
        knownTags: [TagPath],
        excluding currentTags: [TagPath],
        limit: Int = 8
    ) -> [TagPath] {
        let currentPaths = Set(currentTags.map(\.normalizedPath))
        let available = knownTags.filter { !currentPaths.contains($0.normalizedPath) }
        return Array(TagSearch.ranked(available, query: query).prefix(limit))
    }

    private static func searchKeys(for entry: HighlightFeedEntry) -> [String] {
        // Tag segments as words so `ssv` finds `work/ssv` without gluing segments together.
        let tagWords = entry.allTags.map { $0.displayPath.replacingOccurrences(of: "/", with: " ") }
        return ([entry.highlight.selectedText, entry.articleTitle] + tagWords).map(foldForMatching)
    }
}
