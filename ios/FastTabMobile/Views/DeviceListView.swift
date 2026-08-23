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
                VStack(spacing: 12) {
                    Image(systemName: "laptopcomputer.and.iphone")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("No Macs connected")
                        .font(.headline)
                    Text("Make sure FastTab is running on your Mac with iCloud sync enabled.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
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
                                color: .blue,
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
                                color: .yellow,
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
                                color: .gray,
                                title: "Recent History",
                                count: count
                            )
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
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
                .frame(width: 24)
            Text(title)
                .font(.body)
            Spacer()
            Text("\(count)")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }
}
