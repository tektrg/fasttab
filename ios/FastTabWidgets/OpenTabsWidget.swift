import SwiftUI
import WidgetKit

/// W2: how many tabs are open across your Macs, and the three most recent.
struct OpenTabsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "OpenTabsWidget", provider: SnapshotTimelineProvider()) { entry in
            OpenTabsWidgetView(openTabs: entry.snapshot.openTabs)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(WidgetDeepLink.tabs.url)
        }
        .configurationDisplayName("Open Tabs")
        .description("Tabs open on your Macs.")
        .supportedFamilies([.systemMedium])
    }
}

struct OpenTabsWidgetView: View {
    let openTabs: WidgetSnapshot.OpenTabs?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                WidgetHeader(title: "Mac tabs", systemImage: "macwindow.on.rectangle")
                Spacer(minLength: 0)
                Text("\(openTabs?.totalCount ?? 0)")
                    .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                Text("open").font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 92, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                if let recent = openTabs?.recent, !recent.isEmpty {
                    ForEach(recent) { tab in
                        HStack(spacing: 8) {
                            SiteMonogram(domain: tab.domain, size: 22)
                            Text(tab.title).font(.caption.weight(.medium)).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                } else {
                    WidgetEmptyMessage(text: "No tabs synced from your Mac yet.")
                }
            }
        }
    }
}
