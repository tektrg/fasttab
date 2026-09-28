import SwiftUI
import UIKit
import WidgetKit

/// W4 "Shuffle": the card currently on top of the app's Shuffle deck, with its preview image.
struct ShuffleWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ShuffleWidget", provider: SnapshotTimelineProvider()) { entry in
            ShuffleWidgetView(shuffle: entry.snapshot.shuffle)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Shuffle")
        .description("The card on top of your Shuffle deck.")
        .supportedFamilies([.systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

struct ShuffleWidgetView: View {
    let shuffle: WidgetSnapshot.Shuffle?
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let shuffle {
            card(shuffle)
                .widgetURL(WidgetDeepLink.read(url: shuffle.item.url, title: shuffle.item.title, highlightID: shuffle.highlightID).url)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                WidgetHeader(title: "Shuffle", systemImage: "shuffle")
                WidgetEmptyMessage(text: "Open Shuffle in FastTab to deal a card.")
            }
            .padding()
        }
    }

    private func card(_ shuffle: WidgetSnapshot.Shuffle) -> some View {
        let image = shuffle.thumbnailFileName
            .flatMap { UIImage(contentsOfFile: WidgetSnapshotStore.thumbnailURL(named: $0).path) }
        let layout = family == .systemLarge
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 0))
        return layout {
            thumbnail(image, domain: shuffle.item.domain)
            VStack(alignment: .leading, spacing: 4) {
                WidgetHeader(title: "Shuffle", systemImage: "shuffle")
                Text(shuffle.item.title)
                    .font(family == .systemLarge ? .title3.weight(.bold) : .headline)
                    .lineLimit(family == .systemLarge ? 3 : 4)
                Spacer(minLength: 0)
                Text(shuffle.badge).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Text(shuffle.item.domain).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func thumbnail(_ image: UIImage?, domain: String) -> some View {
        // A clear frame sized first, the image overlaid: a scaled-to-fill image would otherwise
        // size the layout off its own pixels.
        Color.clear
            .frame(width: family == .systemLarge ? nil : 140, height: family == .systemLarge ? 190 : nil)
            .frame(maxWidth: family == .systemLarge ? .infinity : nil, maxHeight: family == .systemLarge ? nil : .infinity)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    ZStack {
                        Rectangle().fill(.fill.secondary)
                        SiteMonogram(domain: domain, size: 44)
                    }
                }
            }
            .clipped()
    }
}
