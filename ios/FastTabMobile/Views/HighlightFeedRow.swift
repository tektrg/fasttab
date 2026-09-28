import SwiftUI

/// One row of the Highlights feed: the full highlight (tap opens the article at it) and,
/// under it, the tag / folder / article chips that filter the feed.
struct HighlightFeedRow: View {
    let entry: HighlightFeedEntry
    @Binding var filter: HighlightFeedFilter
    let onOpen: () -> Void

    /// Lines the chips up with the text, past `HighlightSnippetRow`'s colour dot (10pt + gap).
    private static let chipsLeadingInset: CGFloat = 10 + DS.Space.md

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HighlightSnippetRow(
                highlight: entry.highlight,
                articleTitle: entry.articleTitle,
                style: .row,
                showsArticleTitle: false,
                onSelect: onOpen
            )
            HighlightRowChips(entry: entry, filter: $filter)
                .padding(.leading, Self.chipsLeadingInset)
                .padding(.bottom, DS.Space.xs)
        }
    }
}
