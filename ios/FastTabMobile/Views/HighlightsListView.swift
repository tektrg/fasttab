import SwiftUI
import IndieGallery

/// Every saved highlight as a two-column card gallery (IndieGallery), newest first. Each card
/// shows the article, the highlight and chips for its tags and bookmark folder. Tapping a chip
/// filters the feed (chips AND together, a parent tag covers its children); search matches text,
/// article, tag names and comments. Tap opens the article at the highlight; long-press (and the
/// VoiceOver actions) offer Comments, Edit Tags, This Article Only and Delete.
/// Filtering lives in `HighlightFeedModel`. Reached from the Read tab's "See all" and from
/// More → Highlights.
public struct HighlightsListView: View {
    @ObservedObject private var store = ReaderHighlightStore.shared
    @ObservedObject private var localCache = LocalCache.shared
    @ObservedObject private var commentThreads = ReaderCommentThreads.shared
    @State private var filter = HighlightFeedFilter()
    @State private var searchText = ""
    @State private var readerItem: ReaderNavigationItem? = nil
    @State private var taggingEntry: HighlightFeedEntry? = nil
    @State private var commentingEntry: HighlightFeedEntry? = nil

    public init() {}

    private var allEntries: [HighlightFeedEntry] {
        let folderTagsByKey = HighlightFolderTags.memoizedTagsByArticleKey(from: localCache.state.bookmarkBlobs)
        // One title lookup per article, not per highlight: a miss in the resolver checks the
        // disk cache and scans Last Opened, and this runs on every render (each search keystroke).
        var titlesByKey: [String: String] = [:]
        return HighlightFeedModel.entries(
            from: store.allHighlightsNewestFirst(),
            articleTitle: { highlight in
                if let stored = highlight.title,
                   !ReaderHighlightTitleResolver.isPlaceholder(stored, for: highlight.articleURL) { return stored }
                if let title = titlesByKey[highlight.urlKey] { return title }
                let title = ReaderHighlightTitleResolver.resolve(for: highlight)
                titlesByKey[highlight.urlKey] = title
                return title
            },
            folderTags: { folderTagsByKey[$0.urlKey] ?? [] },
            comments: { commentThreads.thread(for: $0)?.messages.compactMap(\.text) ?? [] }
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
                if HighlightFeedModel.showsActiveFilterBar(filter: filter, entries: entries) {
                    HighlightActiveFilterBar(filter: $filter)
                }
            }
            // Deleting the last highlight leaves nothing to filter: drop the filter so it
            // cannot hide highlights added later.
            .onChange(of: entries.isEmpty) { _, isEmpty in
                if isEmpty { filter.clear() }
            }
            .sheet(item: $taggingEntry) { entry in
                HighlightTagEditorSheet(entry: entry, knownTags: HighlightFeedModel.knownTags(in: entries)) { tags in
                    store.setTags(tags, for: entry.highlight)
                }
            }
            .sheet(item: $commentingEntry) { entry in
                HighlightThreadSheet(highlight: entry.highlight) { delete(entry) }
            }
            .onAppear { commentThreads.load(store.allHighlightsNewestFirst()) }
            .readerPresentation(item: $readerItem) { item in
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
            ScrollView {
                IndieGallery(visibleEntries, estimatedHeight: HighlightGalleryCard.estimatedHeight) { entry in
                    galleryCard(entry)
                }
                .padding(.horizontal, DS.Space.gutter)
                .padding(.vertical, DS.Space.md)
            }
            .indieGalleryStyle(.fastTab)
            .dsCanvas()
        }
    }

    private func galleryCard(_ entry: HighlightFeedEntry) -> some View {
        HighlightGalleryCard(entry: entry, filter: $filter) { commentingEntry = entry }
            .onTapGesture { open(entry.highlight) }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { open(entry.highlight) }
            .accessibilityAction(named: "Comments") { commentingEntry = entry }
            .accessibilityAction(named: "Edit Tags") { taggingEntry = entry }
            .accessibilityAction(named: articleFilterLabel(entry)) { toggleArticle(entry) }
            .accessibilityAction(named: "Delete") { delete(entry) }
            .accessibilityActions {
                // The tag chips are hidden from VoiceOver inside the combined card; one action each.
                ForEach(entry.allTags, id: \.normalizedPath) { tag in
                    Button(filter.tagFilter.covers(tag) ? "Remove filter \(tag.displayPath)" : "Filter by \(tag.displayPath)") {
                        withAnimation(DS.Motion.quick) { filter.tagFilter.toggleCovering(tag) }
                    }
                }
            }
            .contextMenu {
                Button { commentingEntry = entry } label: { Label("Comments", systemImage: "text.bubble") }
                Button { taggingEntry = entry } label: { Label("Edit Tags", systemImage: "tag") }
                Button { toggleArticle(entry) } label: { Label(articleFilterLabel(entry), systemImage: "doc.text") }
                Button(role: .destructive) { delete(entry) } label: { Label("Delete", systemImage: "trash") }
            }
    }

    /// The article chip moved off the card (its title names the article), so narrowing the feed
    /// to one article lives in the long-press menu.
    private func articleFilterLabel(_ entry: HighlightFeedEntry) -> String {
        filter.isArticleSelected(entry.highlight.urlKey) ? "Show All Articles" : "This Article Only"
    }

    private func toggleArticle(_ entry: HighlightFeedEntry) {
        withAnimation(DS.Motion.quick) {
            filter.toggleArticle(urlKey: entry.highlight.urlKey, title: entry.articleTitle)
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
