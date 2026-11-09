import SwiftUI
import IndieGallery

/// One highlight as a card in the Highlights gallery (IndieGallery):
/// date · glyph (quote, or a speech bubble when it has comments) / article title /
/// highlighted text with its colour bar / latest comment / tag + folder chips (tap filters).
/// The article chip of the list row is dropped: the title already names the article.
/// Card-level actions (open, comments, tags, delete) are attached by the gallery screen.
struct HighlightGalleryCard: View {
    let entry: HighlightFeedEntry
    @Binding var filter: HighlightFeedFilter

    /// Longest excerpt before it is cut (the full text is one tap away in the reader).
    static let excerptLineLimit = 6

    var body: some View {
        IndieGalleryCard {
            Text(Self.metaText(for: entry.highlight.createdAt))
                .font(DS.Font.meta)
                .foregroundStyle(.secondary)
        } glyph: {
            Image(systemName: entry.comments.isEmpty ? "quote.opening" : "text.bubble")
                .font(DS.Font.meta.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        } title: {
            Text(entry.articleTitle)
                .font(DS.Font.cardTitle)
                .foregroundStyle(.primary)
                .lineLimit(3)
        } excerpt: {
            HStack(alignment: .top, spacing: DS.Space.sm) {
                Capsule()
                    .fill(entry.highlight.color.swiftUIColor)
                    .frame(width: 3)
                    .accessibilityHidden(true)
                Text(entry.highlight.selectedText)
                    .foregroundStyle(.primary.opacity(0.8))
                    .lineLimit(Self.excerptLineLimit)
            }
            .fixedSize(horizontal: false, vertical: true)
        } footer: {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                if let latest = entry.comments.last {
                    Label {
                        Text(entry.comments.count > 1 ? "\(latest) · \(entry.comments.count) comments" : latest)
                            .lineLimit(1)
                    } icon: {
                        Image(systemName: "text.bubble")
                    }
                    .foregroundStyle(.secondary)
                }
                if !entry.allTags.isEmpty {
                    HighlightRowChips(entry: entry, filter: $filter, showsArticle: false)
                }
            }
        }
    }

    /// "Today, 3:15 PM", "Yesterday, 7:45 PM", else "Mar 8, 11:30 AM" (year added when not this year).
    static func metaText(for date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return "Today, \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday, \(time)" }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let day = sameYear
            ? date.formatted(.dateTime.month(.abbreviated).day())
            : date.formatted(.dateTime.month(.abbreviated).day().year())
        return "\(day), \(time)"
    }

    /// Cheap (O(1)-ish) height guess for the gallery's column balancing: fixed chrome plus wrapped
    /// title and excerpt lines from character counts at the column width.
    static func estimatedHeight(_ entry: HighlightFeedEntry, columnWidth: CGFloat) -> CGFloat {
        let textWidth = max(80, columnWidth - 2 * DS.Space.lg - 11)
        let charsPerLine = max(10, textWidth / 7.5)
        func lines(_ count: Int, max limit: Int) -> CGFloat {
            CGFloat(min(limit, max(1, Int((CGFloat(count) / charsPerLine).rounded(.up)))))
        }
        var height: CGFloat = 2 * DS.Space.lg + 16 // padding + meta line
        height += lines(entry.articleTitle.count, max: 3) * 20
        height += lines(entry.highlight.selectedText.count, max: excerptLineLimit) * 20
        if !entry.comments.isEmpty { height += 18 }
        let chips = entry.allTags.count
        if chips > 0 { height += CGFloat((chips + 1) / 2) * 26 }
        return height + 3 * DS.Space.sm
    }
}

extension IndieGalleryStyle {
    /// Fast Tab's theme for galleries: DS surface, card radius and resting shadow.
    static var fastTab: IndieGalleryStyle {
        IndieGalleryStyle(
            cardBackground: AnyShapeStyle(DS.Palette.surface),
            cornerRadius: DS.Radius.lg,
            shadow: .init(color: DS.Shadow.card.color, radius: DS.Shadow.card.radius, y: DS.Shadow.card.y),
            spacing: DS.Space.md,
            cardPadding: DS.Space.lg,
            chipBackground: AnyShapeStyle(DS.Palette.surfaceMuted),
            chipForeground: .secondary
        )
    }
}
