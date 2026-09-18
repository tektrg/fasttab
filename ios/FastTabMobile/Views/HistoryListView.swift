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
    @State private var toastMessage: String?
    @State private var showToast: Bool = false

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
                VStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("No history found")
                        .font(.headline)
                    Text("Recent history from your Mac will sync here.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(filteredHistory) { item in
                        HStack(spacing: 12) {
                            Image(systemName: "clock")
                                .foregroundColor(.secondary)
                                .font(.system(size: 16))

                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.entry.title.isEmpty ? item.entry.url : item.entry.title)
                                    .font(.body)
                                    .lineLimit(1)

                                HStack(spacing: 6) {
                                    Text(item.browser)
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color(uiColor: .tertiarySystemBackground))
                                        .cornerRadius(4)

                                    Text(item.entry.lastVisitedAt, style: .time)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)

                                    Text(item.entry.url)
                                        .font(.caption)
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
                                    withAnimation {
                                        toastMessage = "URL Copied"
                                        showToast = true
                                    }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                                        withAnimation { showToast = false }
                                    }
                                } label: {
                                    Label("Copy URL", systemImage: "doc.on.doc")
                                }

                                Button {
                                    SyncConsumer.shared.sendOpenOnMac(url: item.entry.url, title: item.entry.title.isEmpty ? nil : item.entry.title)
                                    withAnimation {
                                        toastMessage = "Sent to Mac"
                                        showToast = true
                                    }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                                        withAnimation { showToast = false }
                                    }
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
                }
                .listStyle(.insetGrouped)
            }
        }
        .searchable(text: $searchText, prompt: "Search history")
        .fullScreenCover(item: $selectedURLForReader) { url in
            InAppBrowserView(url: url)
                .ignoresSafeArea()
        }
        .fullScreenCover(item: $readerItem) { item in
            ReaderView(url: item.url, title: item.title)
        }
        .overlay(alignment: .bottom) {
            if showToast, let toastMessage {
                Text(toastMessage)
                    .font(.subheadline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                    .cornerRadius(20)
                    .shadow(radius: 4)
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private func queueDeleteHistory(_ item: HistoryRowItem) {
        let targetID = device?.id ?? ""
        SyncConsumer.shared.sendDeleteHistoryItem(
            entry: item.entry,
            browserName: item.browser,
            targetDeviceID: targetID
        )

        withAnimation {
            toastMessage = "Queued history deletion — confirm on your Mac"
            showToast = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
            withAnimation {
                showToast = false
            }
        }
    }
}
