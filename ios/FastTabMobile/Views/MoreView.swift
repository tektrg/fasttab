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
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            Section("Utilities & Intelligence") {
                NavigationLink {
                    DeskQueueView()
                        .navigationTitle("Desk Queue")
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.blue)
                            .frame(width: 26)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Desk Queue")
                                .font(.body.weight(.medium))
                            Text("Links staged to open on your Mac")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if queueCount > 0 {
                            Text("\(queueCount)")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color.blue)
                                .foregroundColor(.white)
                                .clipShape(Capsule())
                        }
                    }
                    .padding(.vertical, 4)
                }

                NavigationLink {
                    IntelligenceView()
                        .navigationTitle("Intelligence")
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 16))
                            .foregroundStyle(.purple)
                            .frame(width: 26)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Intelligence")
                                .font(.body.weight(.medium))
                            Text("Topic clusters & bookmark suggestions")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("Bookmarks & History") {
                NavigationLink {
                    BookmarkTreeView(device: nil)
                        .navigationTitle("Bookmarks")
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.yellow)
                            .frame(width: 26)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Bookmarks")
                                .font(.body.weight(.medium))
                            Text("All synced browser bookmarks & folders")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if bookmarksCount > 0 {
                            Text("\(bookmarksCount)")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                NavigationLink {
                    HistoryListView(device: nil)
                        .navigationTitle("History")
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 16))
                            .foregroundStyle(.orange)
                            .frame(width: 26)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Synced History")
                                .font(.body.weight(.medium))
                            Text("Recent browsing history from your Mac")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("Devices") {
                NavigationLink {
                    DeviceListView()
                        .navigationTitle("Devices")
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "laptopcomputer")
                            .font(.system(size: 16))
                            .foregroundStyle(.teal)
                            .frame(width: 26)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Connected Macs")
                                .font(.body.weight(.medium))
                            Text("\(devicesCount) device\(devicesCount == 1 ? "" : "s") synced")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section {
                Button {
                    Task {
                        await syncConsumer.refreshNow()
                    }
                } label: {
                    HStack {
                        Spacer()
                        Label("Sync Now", systemImage: "arrow.clockwise")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("More")
    }
}
