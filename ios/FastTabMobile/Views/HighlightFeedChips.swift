import SwiftUI
import IndieTags

/// The chips under one highlight in the Highlights feed: its user tags, its bookmark-folder
/// tags (folder icon, bookmark tint) and its article. Tapping one narrows the feed to it;
/// tapping a lit one (selected, or under a selected parent) turns it off again.
struct HighlightRowChips: View {
    let entry: HighlightFeedEntry
    @Binding var filter: HighlightFeedFilter

    var body: some View {
        WrappingRowsLayout(spacing: DS.Space.xs, lineSpacing: DS.Space.xs) {
            ForEach(entry.userTags, id: \.normalizedPath) { tag in
                tagChip(tag, systemImage: "tag", tint: DS.Tint.action)
            }
            ForEach(entry.folderTags, id: \.normalizedPath) { tag in
                tagChip(tag, systemImage: "folder", tint: DS.Tint.bookmark)
            }
            articleChip
        }
    }

    private func tagChip(_ tag: TagPath, systemImage: String, tint: Color) -> some View {
        HighlightChipButton(
            title: tag.displayPath,
            systemImage: systemImage,
            tint: tint,
            isLit: filter.tagFilter.covers(tag),
            accessibilityHint: "Filters highlights by this tag"
        ) {
            filter.tagFilter.toggleCovering(tag)
        }
    }

    private var articleChip: some View {
        HighlightChipButton(
            title: entry.articleTitle,
            systemImage: "doc.text",
            tint: .secondary,
            isLit: filter.isArticleSelected(entry.highlight.urlKey),
            accessibilityHint: "Filters highlights by this article"
        ) {
            filter.toggleArticle(urlKey: entry.highlight.urlKey, title: entry.articleTitle)
        }
    }
}

/// A `DSTag` that can be tapped; a checkmark replaces its icon while it is part of the filter.
private struct HighlightChipButton: View {
    let title: String
    let systemImage: String
    let tint: Color
    let isLit: Bool
    let accessibilityHint: String
    let action: () -> Void

    var body: some View {
        Button {
            withAnimation(DS.Motion.quick) { action() }
        } label: {
            DSTag(title, tint: tint, systemImage: isLit ? "checkmark" : systemImage)
                .frame(maxWidth: 220, alignment: .leading)
                .overlay { if isLit { Capsule().strokeBorder(tint, lineWidth: 1) } }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isLit ? .isSelected : [])
        .accessibilityHint(accessibilityHint)
    }
}

/// The active filter above the feed: one removable chip per selected tag and the selected
/// article, then "Clear".
struct HighlightActiveFilterBar: View {
    @Binding var filter: HighlightFeedFilter

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Space.sm) {
                ForEach(filter.tagFilter.selectedPaths, id: \.normalizedPath) { tag in
                    DSChip(tag.displayPath, systemImage: "xmark", isSelected: true) {
                        filter.tagFilter.remove(tag)
                    }
                    .accessibilityLabel("Remove filter \(tag.displayPath)")
                }
                if let article = filter.article {
                    DSChip(article.title, systemImage: "xmark", isSelected: true) {
                        filter.article = nil
                    }
                    .frame(maxWidth: 240)
                    .accessibilityLabel("Remove article filter \(article.title)")
                }
                Button("Clear") {
                    withAnimation(DS.Motion.quick) { filter.clear() }
                }
                .font(DS.Font.control)
            }
            .padding(.horizontal, DS.Space.gutter)
            .padding(.vertical, DS.Space.sm)
        }
        .background(.bar)
    }
}
