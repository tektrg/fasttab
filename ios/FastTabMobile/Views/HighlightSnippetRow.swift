import SwiftUI
import UIKit

/// One highlight's snippet + the article it came from: a colour dot, the highlighted
/// text (primary line, up to 3 lines), and the resolved article title (secondary line).
/// Reused both as a carousel card (`.card`) on the Read tab and as a plain list row
/// (`.row`) in `HighlightsListView`.
public struct HighlightSnippetRow: View {
    public enum Style { case card, row }

    let highlight: ReaderHighlight
    let articleTitle: String
    let style: Style
    let onSelect: () -> Void

    public init(highlight: ReaderHighlight, articleTitle: String, style: Style, onSelect: @escaping () -> Void) {
        self.highlight = highlight
        self.articleTitle = articleTitle
        self.style = style
        self.onSelect = onSelect
    }

    public var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onSelect()
        } label: {
            switch style {
            case .card: cardBody
            case .row: rowBody
            }
        }
        .buttonStyle(.plain)
    }

    private var colorDot: some View {
        Circle()
            .fill(highlight.color.swiftUIColor)
            .frame(width: 10, height: 10)
            .accessibilityHidden(true)
    }

    private var snippetText: some View {
        Text(highlight.selectedText)
            .font(DS.Font.body)
            .foregroundStyle(.primary)
            // Cards reserve all 3 lines so every card in the carousel has the same height.
            .lineLimit(3, reservesSpace: style == .card)
            .multilineTextAlignment(.leading)
    }

    private var articleTitleText: some View {
        Text(articleTitle)
            .font(DS.Font.meta)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            colorDot
            snippetText
            Spacer(minLength: 0)
            articleTitleText
        }
        .padding(DS.Space.md)
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
        .background(DS.Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                .strokeBorder(DS.Palette.hairline, lineWidth: 1)
        }
        .dsShadow(.card)
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous))
    }

    private var rowBody: some View {
        HStack(alignment: .top, spacing: DS.Space.md) {
            colorDot
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                snippetText
                articleTitleText
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, DS.Space.xs)
        .contentShape(Rectangle())
    }
}
