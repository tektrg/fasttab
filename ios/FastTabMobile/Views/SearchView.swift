import SwiftUI
import FastTabSync

public enum SearchScope: String, CaseIterable, Identifiable {
    case all = "All"
    case tabs = "Tabs"
    case bookmarks = "Bookmarks"
    case history = "History"

    public var id: String { rawValue }
}

public struct UnifiedSearchResult: Identifiable {
    public let id: String
    public let title: String
    public let url: String
    public let browserName: String
    public let type: SyncSearchType
    public let timestamp: Date
    public let folderOrWindow: String?

    public enum SyncSearchType: String {
        case tab
        case bookmark
        case history

        public var icon: String {
            switch self {
            case .tab: return "globe"
            case .bookmark: return "bookmark.fill"
            case .history: return "clock"
            }
        }

        public var color: Color {
            switch self {
            case .tab: return DS.Tint.action
            case .bookmark: return DS.Tint.bookmark
            case .history: return .secondary
            }
        }
    }
}

public struct SearchView: View {
    @ObservedObject var localCache = LocalCache.shared

    @State private var query: String = ""
    @State private var scope: SearchScope = .all
    @State private var selectedURLForReader: URL?
    @State private var readerItem: ReaderNavigationItem?
    @State private var toast: String?

    public init() {}

    private var allUnifiedItems: [UnifiedSearchResult] {
        var items: [UnifiedSearchResult] = []

        // Tabs
        for tab in localCache.state.tabs {
            items.append(UnifiedSearchResult(
                id: "tab_\(tab.id)",
                title: tab.title.isEmpty ? tab.url : tab.title,
                url: tab.url,
                browserName: tab.browserName,
                type: .tab,
                timestamp: tab.timestamp,
                folderOrWindow: tab.windowName
            ))
        }

        // Bookmarks
        for blob in localCache.state.bookmarkBlobs {
            for bm in blob.bookmarks {
                items.append(UnifiedSearchResult(
                    id: "bm_\(bm.id)",
                    title: bm.title.isEmpty ? bm.url : bm.title,
                    url: bm.url,
                    browserName: blob.browserName,
                    type: .bookmark,
                    timestamp: bm.dateAdded ?? Date(),
                    folderOrWindow: bm.folderPath
                ))
            }
        }

        // History
        for slice in localCache.state.historySlices {
            for entry in slice.entries {
                items.append(UnifiedSearchResult(
                    id: "hist_\(entry.id)",
                    title: entry.title.isEmpty ? entry.url : entry.title,
                    url: entry.url,
                    browserName: slice.browserName,
                    type: .history,
                    timestamp: entry.lastVisitedAt,
                    folderOrWindow: nil
                ))
            }
        }

        return items
    }

    private var matchingResults: [UnifiedSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let filteredByScope: [UnifiedSearchResult]
        switch scope {
        case .all:
            filteredByScope = allUnifiedItems
        case .tabs:
            filteredByScope = allUnifiedItems.filter { $0.type == .tab }
        case .bookmarks:
            filteredByScope = allUnifiedItems.filter { $0.type == .bookmark }
        case .history:
            filteredByScope = allUnifiedItems.filter { $0.type == .history }
        }

        var out: [UnifiedSearchResult] = []
        for item in filteredByScope {
            if SyncSearchMatcher.matches(query: trimmed, title: item.title, url: item.url) {
                out.append(item)
            }
        }
        return out
    }

    public var body: some View {
        VStack(spacing: 0) {
            Picker("Scope", selection: $scope) {
                ForEach(SearchScope.allCases) { s in
                    Text(s.rawValue).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, DS.Space.gutter)
            .padding(.vertical, DS.Space.sm)

            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                DSEmptyState(
                    "FastTab Instant Search",
                    systemImage: "magnifyingglass",
                    message: "Search tabs, bookmarks, and history across all your synced Macs."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if matchingResults.isEmpty {
                DSEmptyState(
                    "No results for \"\(query)\"",
                    systemImage: "text.magnifyingglass",
                    message: "Check spelling or broaden your search terms."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(matchingResults) { item in
                        HStack(spacing: DS.Space.md) {
                            Image(systemName: item.type.icon)
                                .foregroundColor(item.type.color)
                                .font(.system(size: DS.IconSize.row))

                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title)
                                    .font(DS.Font.body)
                                    .lineLimit(1)

                                HStack(spacing: 6) {
                                    Text(item.browserName)
                                        .font(DS.Font.tag)
                                        .foregroundColor(.secondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, DS.Space.xxs)
                                        .background(DS.Palette.surfaceMuted, in: RoundedRectangle(cornerRadius: DS.Radius.xs, style: .continuous))

                                    if let extra = item.folderOrWindow, !extra.isEmpty {
                                        Text(extra)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }

                                    Text(item.url)
                                        .font(DS.Font.meta)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if let url = URL(string: item.url) {
                                selectedURLForReader = url
                            }
                        }
                        .contextMenu {
                            if let url = URL(string: item.url) {
                                Button {
                                    readerItem = ReaderNavigationItem(url: url, title: item.title)
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
                                    UIPasteboard.general.string = item.url
                                    toast = "URL Copied"
                                } label: {
                                    Label("Copy URL", systemImage: "doc.on.doc")
                                }

                                Button {
                                    SyncConsumer.shared.sendOpenOnMac(url: item.url, title: item.title.isEmpty ? nil : item.title)
                                    toast = "Sent to Mac"
                                } label: {
                                    Label("Open on Mac", systemImage: "laptopcomputer")
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
        .searchable(text: $query, prompt: "Search tabs, bookmarks & history")
        .fullScreenCover(item: $selectedURLForReader) { url in
            InAppBrowserView(url: url)
                .ignoresSafeArea()
        }
        .fullScreenCover(item: $readerItem) { item in
            ReaderView(url: item.url, title: item.title, focusHighlightID: item.focusHighlightID)
        }
        .dsToast($toast, bottomInset: DS.Space.xl)
    }
}
