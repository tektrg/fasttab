import SwiftUI
import FastTabSync

public struct MoreView: View {
    @ObservedObject private var localCache = LocalCache.shared
    @ObservedObject private var syncConsumer = SyncConsumer.shared

    public init() {}

    private var queueCount: Int {
        localCache.state.sentCommands.filter { cmd in
            cmd.kind == .openOnMac && cmd.status == .pending
        }.count
    }

    private var bookmarksCount: Int {
        localCache.state.bookmarkBlobs.reduce(0) { $0 + $1.bookmarks.count }
    }

    private var devicesCount: Int {
        localCache.state.devices.count
    }

    public var body: some View {
        List {
            Section {
                DataFreshnessBanner(
                    device: localCache.state.devices.first,
                    lastSyncedAt: localCache.state.lastSyncedAt
                )
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            Section("Utilities & Intelligence") {
                NavigationLink {
                    DeskQueueView()
                        .navigationTitle("Desk Queue")
                } label: {
                    MoreRowLabel(
                        systemImage: "paperplane.fill",
                        tint: DS.Tint.action,
                        title: "Desk Queue",
                        subtitle: "Links staged to open on your Mac"
                    ) {
                        if queueCount > 0 {
                            // Solid badge: pending sends are waiting on the Mac.
                            Text("\(queueCount)")
                                .font(DS.Font.tag.monospacedDigit())
                                .padding(.horizontal, DS.Space.sm)
                                .padding(.vertical, 3)
                                .foregroundColor(.white)
                                .background(DS.Tint.action, in: Capsule())
                        }
                    }
                }

                NavigationLink {
                    IntelligenceView()
                        .navigationTitle("Intelligence")
                } label: {
                    MoreRowLabel(
                        systemImage: "sparkles",
                        tint: DS.Tint.emerging,
                        title: "Intelligence",
                        subtitle: "Topic clusters & bookmark suggestions"
                    )
                }
            }
            .dsListRow()

            Section("Bookmarks & History") {
                NavigationLink {
                    BookmarkTreeView(device: nil)
                        .navigationTitle("Bookmarks")
                } label: {
                    MoreRowLabel(
                        systemImage: "bookmark.fill",
                        tint: DS.Tint.bookmark,
                        title: "Bookmarks",
                        subtitle: "All synced browser bookmarks & folders"
                    ) {
                        if bookmarksCount > 0 {
                            DSCountPill(bookmarksCount)
                        }
                    }
                }

                NavigationLink {
                    HistoryListView(device: nil)
                        .navigationTitle("History")
                } label: {
                    MoreRowLabel(
                        systemImage: "clock.arrow.circlepath",
                        tint: .secondary,
                        title: "Synced History",
                        subtitle: "Recent browsing history from your Mac"
                    )
                }
            }
            .dsListRow()

            Section("Devices") {
                NavigationLink {
                    DeviceListView()
                        .navigationTitle("Devices")
                } label: {
                    MoreRowLabel(
                        systemImage: "laptopcomputer",
                        tint: DS.Tint.action,
                        title: "Connected Macs",
                        subtitle: "\(devicesCount) device\(devicesCount == 1 ? "" : "s") synced"
                    )
                }
            }
            .dsListRow()

            Section {
                Button {
                    Task {
                        await syncConsumer.refreshNow()
                    }
                } label: {
                    HStack {
                        Spacer()
                        Label("Sync Now", systemImage: "arrow.clockwise")
                            .font(DS.Font.cardTitle)
                        Spacer()
                    }
                }
            }
            .dsListRow()
        }
        .listStyle(.insetGrouped)
        .dsListStyle()
        .navigationTitle("More")
    }
}

/// Leading tinted icon, title + subtitle, optional trailing accessory — one More row.
private struct MoreRowLabel<Trailing: View>: View {
    let systemImage: String
    let tint: Color
    let title: String
    let subtitle: String
    let trailing: Trailing

    init(systemImage: String, tint: Color, title: String, subtitle: String, @ViewBuilder trailing: () -> Trailing) {
        self.systemImage = systemImage
        self.tint = tint
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: DS.Space.md) {
            Image(systemName: systemImage)
                .font(.system(size: DS.IconSize.row))
                .foregroundStyle(tint)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(title)
                    .font(DS.Font.body.weight(.medium))
                Text(subtitle)
                    .font(DS.Font.meta)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            trailing
        }
        .padding(.vertical, DS.Space.xs)
    }
}

private extension MoreRowLabel where Trailing == EmptyView {
    init(systemImage: String, tint: Color, title: String, subtitle: String) {
        self.init(systemImage: systemImage, tint: tint, title: title, subtitle: subtitle) { EmptyView() }
    }
}
