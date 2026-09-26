import SwiftUI
import FastTabSync

public struct HistoryRowItem: Identifiable {
    public var id: String { "\(browser)|\(entry.id)" }
    public let browser: String
    public let entry: SyncedHistoryEntry
}

public struct HistoryListView: View {
    @ObservedObject var localCache = LocalCache.shared
    public let device: SyncedDevice?

    @State private var searchText: String = ""
    @State private var selectedURLForReader: URL?
    @State private var readerItem: ReaderNavigationItem?
    @State private var toast: String?

    public init(device: SyncedDevice?) {
        self.device = device
    }

    private var allHistory: [HistoryRowItem] {
        let slices = localCache.state.historySlices.filter {
            if let device { return $0.deviceID == device.id }
            return true
        }

        var results: [HistoryRowItem] = []
        for slice in slices {
            for entry in slice.entries {
                results.append(HistoryRowItem(browser: slice.browserName, entry: entry))
            }
        }
        return results.sorted { $0.entry.lastVisitedAt > $1.entry.lastVisitedAt }
    }

    private var filteredHistory: [HistoryRowItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            return allHistory
        }
        var matches: [HistoryRowItem] = []
        for item in allHistory {
            if SyncSearchMatcher.matches(query: query, target: item.entry.title) ||
               SyncSearchMatcher.matches(query: query, target: item.entry.url) {
                matches.append(item)
            }
        }
        return matches
    }

    public var body: some View {
        VStack(spacing: 0) {
            if filteredHistory.isEmpty {
                DSEmptyState(
                    "No history found",
                    systemImage: "clock.arrow.circlepath",
                    message: "Recent history from your Mac will sync here."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(filteredHistory) { item in
                        HStack(spacing: DS.Space.md) {
                            Image(systemName: "clock")
                                .foregroundColor(.secondary)
                                .font(.system(size: DS.IconSize.row))

                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.entry.title.isEmpty ? item.entry.url : item.entry.title)
                                    .font(DS.Font.body)
                                    .lineLimit(1)

                                HStack(spacing: 6) {
                                    Text(item.browser)
                                        .font(DS.Font.tag)
                                        .foregroundColor(.secondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, DS.Space.xxs)
                                        .background(DS.Palette.surfaceMuted, in: RoundedRectangle(cornerRadius: DS.Radius.xs, style: .continuous))

                                    Text(item.entry.lastVisitedAt, style: .time)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)

                                    Text(item.entry.url)
                                        .font(DS.Font.meta)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if let url = URL(string: item.entry.url) {
                                selectedURLForReader = url
                            }
                        }
                        .contextMenu {
                            if let url = URL(string: item.entry.url) {
                                Button {
                                    readerItem = ReaderNavigationItem(url: url, title: item.entry.title)
                                } label: {
                                    Label("Open in Reader", systemImage: "doc.plaintext")
                                }

                                Link(destination: url) {
                                    Label("Open in Safari", systemImage: "safari")
                                }

                                ShareLink(item: url) {
                                    Label("Share Link", systemImage: "square.and.arrow.up")
                                }

                                Button {
                                    UIPasteboard.general.string = item.entry.url
                                    toast = "URL Copied"
                                } label: {
                                    Label("Copy URL", systemImage: "doc.on.doc")
                                }

                                Button {
                                    SyncConsumer.shared.sendOpenOnMac(url: item.entry.url, title: item.entry.title.isEmpty ? nil : item.entry.title)
                                    toast = "Sent to Mac"
                                } label: {
                                    Label("Open on Mac", systemImage: "laptopcomputer")
                                }

                                if !item.browser.lowercased().contains("safari") {
                                    Divider()
                                    Button(role: .destructive) {
                                        queueDeleteHistory(item)
                                    } label: {
                                        Label("Delete History Item", systemImage: "trash")
                                    }
                                }
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if !item.browser.lowercased().contains("safari") {
                                Button(role: .destructive) {
                                    queueDeleteHistory(item)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .dsListRow()
                }
                .listStyle(.insetGrouped)
                .dsListStyle()
            }
        }
        .dsCanvas()
        .searchable(text: $searchText, prompt: "Search history")
        .fullScreenCover(item: $selectedURLForReader) { url in
            InAppBrowserView(url: url)
                .ignoresSafeArea()
        }
        .fullScreenCover(item: $readerItem) { item in
            ReaderView(url: item.url, title: item.title)
        }
        .dsToast($toast, bottomInset: DS.Space.xl, duration: DS.Motion.toastLongDuration)
    }

    private func queueDeleteHistory(_ item: HistoryRowItem) {
        let targetID = device?.id ?? ""
        SyncConsumer.shared.sendDeleteHistoryItem(
            entry: item.entry,
            browserName: item.browser,
            targetDeviceID: targetID
        )
        toast = "Queued history deletion — confirm on your Mac"
    }
}
