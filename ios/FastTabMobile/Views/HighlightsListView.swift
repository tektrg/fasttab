import SwiftUI

/// Every saved highlight in one flat feed, newest first, each shown in full with chips for
/// its tags, its bookmark folder and its article. Tapping a chip filters the feed (chips AND
/// together, a parent tag covers its children); search matches text, article and tag names.
/// Filtering lives in `HighlightFeedModel`. Reached from the Read tab's "See all" and from
/// More → Highlights.
public struct HighlightsListView: View {
    @ObservedObject private var store = ReaderHighlightStore.shared
    @ObservedObject private var localCache = LocalCache.shared
    @State private var filter = HighlightFeedFilter()
    @State private var searchText = ""
    @State private var readerItem: ReaderNavigationItem? = nil
    @State private var taggingEntry: HighlightFeedEntry? = nil

    public init() {}

    private var allEntries: [HighlightFeedEntry] {
        let folderTagsByKey = HighlightFolderTags.tagsByArticleKey(from: localCache.state.bookmarkBlobs)
        return HighlightFeedModel.entries(
            from: store.allHighlightsNewestFirst(),
            articleTitle: { ReaderHighlightTitleResolver.resolve(for: $0) },
            folderTags: { folderTagsByKey[$0.urlKey] ?? [] }
        )
    }

    public var body: some View {
        let entries = allEntries
        let visibleEntries = HighlightFeedModel.visibleEntries(entries, filter: filter, searchText: searchText)
        return content(entries: entries, visibleEntries: visibleEntries)
            .navigationTitle("Highlights")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search highlights, articles, tags")
            .safeAreaInset(edge: .top, spacing: 0) {
                if filter.isActive { HighlightActiveFilterBar(filter: $filter) }
            }
            .sheet(item: $taggingEntry) { entry in
                HighlightTagEditorSheet(entry: entry, knownTags: HighlightFeedModel.knownTags(in: entries)) { tags in
                    store.setTags(tags, for: entry.highlight)
                }
            }
            .fullScreenCover(item: $readerItem) { item in
                ReaderView(url: item.url, title: item.title, focusHighlightID: item.focusHighlightID)
            }
    }

    @ViewBuilder
    private func content(entries: [HighlightFeedEntry], visibleEntries: [HighlightFeedEntry]) -> some View {
        if entries.isEmpty {
            emptyState("No highlights yet", systemImage: "highlighter",
                       message: "Long-press any text in the article reader to add a highlight. They'll show up here.")
        } else if visibleEntries.isEmpty {
            emptyState("No matching highlights", systemImage: "magnifyingglass",
                       message: "Try another search, or remove a filter.")
        } else {
            List {
                ForEach(visibleEntries) { entry in
                    feedRow(entry)
                }
                .dsListRow()
            }
            .dsListStyle()
        }
    }

    private func feedRow(_ entry: HighlightFeedEntry) -> some View {
        HighlightFeedRow(entry: entry, filter: $filter) { open(entry.highlight) }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) { delete(entry) } label: { Label("Delete", systemImage: "trash") }
            }
            .swipeActions(edge: .leading) {
                Button { taggingEntry = entry } label: { Label("Tags", systemImage: "tag") }
                    .tint(DS.Tint.action)
            }
            .contextMenu {
                Button { taggingEntry = entry } label: { Label("Edit Tags", systemImage: "tag") }
                Button(role: .destructive) { delete(entry) } label: { Label("Delete", systemImage: "trash") }
            }
    }

    private func emptyState(_ title: String, systemImage: String, message: String) -> some View {
        DSEmptyState(title, systemImage: systemImage, message: message)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .dsCanvas()
    }

    private func delete(_ entry: HighlightFeedEntry) {
        withAnimation { store.remove(entry.highlight) }
    }

    private func open(_ highlight: ReaderHighlight) {
        guard let url = highlight.articleURL else { return }
        let title = ReaderHighlightTitleResolver.resolve(for: highlight)
        LastOpenedStore.shared.recordOpened(url: url, title: title)
        readerItem = ReaderNavigationItem(url: url, title: title, focusHighlightID: highlight.id)
    }
}
