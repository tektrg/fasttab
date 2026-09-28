import SwiftUI
import WidgetKit

/// W1: the newest saved links not read yet. Small shows one, medium three.
struct UpNextWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "UpNextWidget", provider: SnapshotTimelineProvider()) { entry in
            UpNextWidgetView(links: entry.snapshot.upNext)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Up Next")
        .description("Your newest saved links you haven't read yet.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct UpNextWidgetView: View {
    let links: [WidgetSnapshot.Link]
    @Environment(\.widgetFamily) private var family

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WidgetHeader(title: "Up next", systemImage: "book")
            if links.isEmpty {
                WidgetEmptyMessage(text: "All caught up. Links you save show up here.")
            } else if family == .systemSmall, let link = links.first {
                smallBody(link)
            } else {
                ForEach(links) { WidgetLinkRow(link: $0) }
                Spacer(minLength: 0)
            }
        }
    }

    private func smallBody(_ link: WidgetSnapshot.Link) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SiteMonogram(domain: link.domain, size: 34)
            Spacer(minLength: 0)
            Text(link.title).font(.subheadline.weight(.semibold)).lineLimit(3)
            Text(link.domain).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(WidgetDeepLink.read(url: link.url, title: link.title, highlightID: nil).url)
    }
}
