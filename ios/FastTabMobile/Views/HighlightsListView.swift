import SwiftUI

/// All saved highlights across every article, newest first, grouped into one section
/// per article (section order = that article's most recent highlight). Reached from the
/// Read tab's "See all" and from More → Highlights.
public struct HighlightsListView: View {
    @ObservedObject private var store = ReaderHighlightStore.shared
    @State private var readerItem: ReaderNavigationItem? = nil

    public init() {}

    /// One row per distinct article, each carrying its highlights newest first; rows are
    /// ordered by their most recent highlight since `store.allHighlightsNewestFirst()` is
    /// already sorted newest first overall.
    private struct ArticleGroup: Identifiable {
        let urlKey: String
        let title: String
        let highlights: [ReaderHighlight]
        var id: String { urlKey }
    }

    private var groupedByArticle: [ArticleGroup] {
        var order: [String] = []
        var buckets: [String: [ReaderHighlight]] = [:]
        for highlight in store.allHighlightsNewestFirst() {
            if buckets[highlight.urlKey] == nil {
                order.append(highlight.urlKey)
                buckets[highlight.urlKey] = []
            }
            buckets[highlight.urlKey, default: []].append(highlight)
        }
        return order.map { key in
            let highlights = buckets[key] ?? []
            let title = highlights.first.map { ReaderHighlightTitleResolver.resolve(for: $0) } ?? key
            return ArticleGroup(urlKey: key, title: title, highlights: highlights)
        }
    }

    public var body: some View {
        Group {
            if groupedByArticle.isEmpty {
                DSEmptyState(
                    "No highlights yet",
                    systemImage: "highlighter",
                    message: "Long-press any text in the article reader to add a highlight. They'll show up here."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .dsCanvas()
            } else {
                List {
                    ForEach(groupedByArticle) { group in
                        Section(group.title) {
                            ForEach(group.highlights) { highlight in
                                HighlightSnippetRow(
                                    highlight: highlight,
                                    articleTitle: group.title,
                                    style: .row
                                ) {
                                    open(highlight)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        withAnimation {
                                            store.remove(highlight)
                                        }
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                        .dsListRow()
                    }
                }
                .dsListStyle()
            }
        }
        .navigationTitle("Highlights")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $readerItem) { item in
            ReaderView(url: item.url, title: item.title, focusHighlightID: item.focusHighlightID)
        }
    }

    private func open(_ highlight: ReaderHighlight) {
        guard let url = highlight.articleURL else { return }
        let title = ReaderHighlightTitleResolver.resolve(for: highlight)
        LastOpenedStore.shared.recordOpened(url: url, title: title)
        readerItem = ReaderNavigationItem(url: url, title: title, focusHighlightID: highlight.id)
    }
}
