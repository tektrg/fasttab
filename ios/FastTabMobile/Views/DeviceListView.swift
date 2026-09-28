import SwiftUI
import FastTabSync

public struct DeviceListView: View {
    @ObservedObject var localCache = LocalCache.shared

    public init() {}

    private var devices: [SyncedDevice] {
        localCache.state.devices
    }

    public var body: some View {
        List {
            if devices.isEmpty {
                DSEmptyState(
                    "No Macs connected",
                    systemImage: "laptopcomputer.and.iphone",
                    message: "Make sure FastTab is running on your Mac with iCloud sync enabled."
                ) {
                    OnboardingShortcutButton(shortcut: .connectMac)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .listRowBackground(Color.clear)
            } else {
                ForEach(devices) { device in
                    Section(header: HStack {
                        Text(device.name)
                            .font(.headline)
                        Spacer()
                        Text(device.modelName)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }) {
                        NavigationLink {
                            TabListView(device: device)
                                .navigationTitle("Tabs — \(device.name)")
                        } label: {
                            DeviceSectionRow(
                                icon: "macwindow",
                                color: DS.Tint.action,
                                title: "Open Tabs",
                                count: localCache.state.tabs.filter { $0.deviceID == device.id }.count
                            )
                        }

                        NavigationLink {
                            BookmarkTreeView(device: device)
                                .navigationTitle("Bookmarks — \(device.name)")
                        } label: {
                            let count = localCache.state.bookmarkBlobs
                                .filter { $0.deviceID == device.id }
                                .reduce(0) { $0 + $1.bookmarks.count }
                            DeviceSectionRow(
                                icon: "bookmark.fill",
                                color: DS.Tint.bookmark,
                                title: "Bookmarks",
                                count: count
                            )
                        }

                        NavigationLink {
                            HistoryListView(device: device)
                                .navigationTitle("History — \(device.name)")
                        } label: {
                            let count = localCache.state.historySlices
                                .filter { $0.deviceID == device.id }
                                .reduce(0) { $0 + $1.entries.count }
                            DeviceSectionRow(
                                icon: "clock.fill",
                                color: .secondary,
                                title: "Recent History",
                                count: count
                            )
                        }
                    }
                    .dsListRow()
                }
            }
        }
        .listStyle(.insetGrouped)
        .dsListStyle()
        .refreshable {
            await SyncConsumer.shared.refreshNow()
        }
    }
}

private struct DeviceSectionRow: View {
    let icon: String
    let color: Color
    let title: String
    let count: Int

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: DS.Space.xl)
            Text(title)
                .font(DS.Font.body)
            Spacer()
            DSCountPill(count)
        }
        .padding(.vertical, DS.Space.xxs)
    }
}
