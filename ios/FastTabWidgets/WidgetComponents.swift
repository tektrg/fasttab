import SwiftUI
import WidgetKit

enum WidgetPalette {
    static let accent = Color.orange
    static let ring = Color(red: 0.98, green: 0.27, blue: 0.37)
}

/// Rounded tile with the site's first letter, the widget's stand-in for a favicon
/// (widgets cannot fetch icons, and the snapshot stays text-only apart from Shuffle's image).
struct SiteMonogram: View {
    let domain: String
    var size: CGFloat = 28

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(Self.color(for: domain).gradient)
            .frame(width: size, height: size)
            .overlay(
                Text(domain.first.map { String($0).uppercased() } ?? "•")
                    .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            )
    }

    /// Stable per domain, so a site keeps its color across reloads.
    private static func color(for domain: String) -> Color {
        let palette: [Color] = [.blue, .indigo, .purple, .pink, .orange, .teal, .green, .brown]
        let hash = domain.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
        return palette[hash % palette.count]
    }
}

/// Title + domain row, tappable in medium/large widgets.
struct WidgetLinkRow: View {
    let link: WidgetSnapshot.Link

    var body: some View {
        Link(destination: WidgetDeepLink.read(url: link.url, title: link.title, highlightID: nil).url) {
            HStack(spacing: 8) {
                SiteMonogram(domain: link.domain)
                VStack(alignment: .leading, spacing: 1) {
                    Text(link.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(link.domain).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

struct WidgetHeader: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(WidgetPalette.accent)
            .lineLimit(1)
    }
}

/// Shown when the app has not written anything for this widget yet.
struct WidgetEmptyMessage: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}
