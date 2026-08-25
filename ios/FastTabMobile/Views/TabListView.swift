import SwiftUI
import FastTabSync

public enum TabSortMode: String, CaseIterable, Identifiable {
    case recent = "Recent"
    case domain = "Domain"
    case windows = "Windows"

    public var id: String { rawValue }
}

public struct TabListView: View {
    @ObservedObject var localCache = LocalCache.shared
    public let device: SyncedDevice?

    @State private var searchText: String = ""
    @State private var sortMode: TabSortMode = .recent
    @State private var selectedURLForReader: URL?
    /// Tabs the user asked to close, each tied to the command that carries the
    /// request. View-local because the association is view-local; every *outcome*
    /// is read back from `LocalCache` so a row is only ever hidden while the
    /// close is genuinely still on its way or genuinely done.
    @State private var pendingCloses: [PendingTabClose] = []
    @State private var toastMessage: String?
    @State private var showToast: Bool = false
    /// The tab awaiting a "save as bookmark" destination. Drives the same
    /// `BookmarkMovePicker` the bookmarks tree uses; on confirm the tab's URL
    /// is saved into the picked folder on the tab's own Mac.
    @State private var tabSaveRequest: TabSaveRequest?

    public init(device: SyncedDevice? = nil) {
        self.device = device
    }

    private var activeDevice: SyncedDevice? {
        device ?? localCache.state.devices.first
    }

    private var visibleTabs: [SyncedTab] {
        let allTabs = localCache.state.tabs
        let filteredByDevice: [SyncedTab]
        if let targetDevice = activeDevice {
            filteredByDevice = allTabs.filter { $0.deviceID == targetDevice.id }
        } else {
            filteredByDevice = allTabs
        }
        return filteredByDevice.filter { !hiddenTabIDs.contains($0.id) }
    }

    // MARK: - Close requests in flight

    /// The live outcome of one close request, or `nil` if its command is no
    /// longer on record (cancelled, or aged out of the history) — in which case
    /// nothing is known and nothing may stay hidden.
    private func progress(for pending: PendingTabClose) -> CommandProgress? {
        guard let command = localCache.state.sentCommands.first(where: { $0.id == pending.commandID }) else {
            return nil
        }
        return CommandProgress.of(
            command: command,
            delivery: localCache.delivery(forCommandID: pending.commandID)
        )
    }

    private var trackedCloses: [TrackedTabClose] {
        pendingCloses.compactMap { pending in
            guard let progress = progress(for: pending) else { return nil }
            return TrackedTabClose(close: pending, progress: progress)
        }
    }

    /// A row disappears only while the close is still travelling or has actually
    /// happened. A failure — refused, expired, or a tab the Mac could not find —
    /// puts it straight back, because the tab is still open over there.
    private var hiddenTabIDs: Set<String> {
        Set(trackedCloses.filter { !$0.progress.isFailure }.map(\.close.tabID))
    }

    /// Drops requests nothing can display any more: the Mac confirmed the close
    /// and the tab has since left the synced list, or the command itself is gone.
    private func pruneFinishedCloses() {
        let liveTabIDs = Set(localCache.state.tabs.map(\.id))
        pendingCloses.removeAll { pending in
            guard let progress = progress(for: pending) else { return true }
            return progress.stage == .succeeded && !liveTabIDs.contains(pending.tabID)
        }
    }

    // Combined search results
    private var matchingTabs: [SyncedTab] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return visibleTabs.filter { tab in
            SyncSearchMatcher.matches(query: q, title: tab.title, url: tab.url)
        }
    }

    private var matchingBookmarks: [(blob: SyncedBookmarkBlob, item: SyncedBookmarkItem)] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }

        var results: [(blob: SyncedBookmarkBlob, item: SyncedBookmarkItem)] = []
        for blob in localCache.state.bookmarkBlobs {
            if let dev = activeDevice, blob.deviceID != dev.id { continue }
            for bm in blob.bookmarks {
                if SyncSearchMatcher.matches(query: q, title: bm.title, url: bm.url) {
                    results.append((blob, bm))
                }
            }
        }
        return results
    }

    private var matchingHistory: [(slice: SyncedHistorySlice, entry: SyncedHistoryEntry)] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }

        var results: [(slice: SyncedHistorySlice, entry: SyncedHistoryEntry)] = []
        for slice in localCache.state.historySlices {
            if let dev = activeDevice, slice.deviceID != dev.id { continue }
            for entry in slice.entries {
                if SyncSearchMatcher.matches(query: q, title: entry.title, url: entry.url) {
                    results.append((slice, entry))
                }
            }
        }
        return results
    }

    /// A tab awaiting a "save as bookmark" destination. Wraps the tab so the
    /// destination picker can be presented as an `Identifiable` sheet item.
    private struct TabSaveRequest: Identifiable {
        let tab: SyncedTab
        var id: String { tab.id }
    }

    // Grouping for Windows mode
    private struct WindowTabGroup: Identifiable {
        let id: String
        let browser: String
        let window: String
        let tabs: [SyncedTab]
    }

    private var tabsByBrowserAndWindow: [WindowTabGroup] {
        var groups: [String: [SyncedTab]] = [:]
        for tab in visibleTabs {
            let winName = tab.windowName ?? ""
            let winLabel = winName.isEmpty ? "Window \(tab.windowIndex ?? 1)" : winName
            let key = "\(tab.browserName) — \(winLabel)"
            groups[key, default: []].append(tab)
        }

        return groups.map { key, tabs in
            let parts = key.split(separator: "—", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            let browser = parts.first ?? "Browser"
            let window = parts.count > 1 ? parts[1] : "Window"
            let sortedTabs = tabs.sorted { ($0.tabIndex ?? 0) < ($1.tabIndex ?? 0) }
            return WindowTabGroup(id: key, browser: browser, window: window, tabs: sortedTabs)
        }.sorted { ($0.browser, $0.window) < ($1.browser, $1.window) }
    }

    // Grouping for Domain mode
    private struct DomainTabGroup: Identifiable {
        let id: String
        let domain: String
        let tabs: [SyncedTab]
    }

    private var tabsByDomain: [DomainTabGroup] {
        var groups: [String: [SyncedTab]] = [:]
        for tab in visibleTabs {
            let host = URL(string: tab.url)?.host() ?? "other"
            groups[host, default: []].append(tab)
        }

        return groups.map { domain, tabs in
            DomainTabGroup(id: domain, domain: domain, tabs: tabs)
        }.sorted { $0.tabs.count > $1.tabs.count }
    }

    public var body: some View {
        VStack(spacing: 0) {
            DataFreshnessBanner(device: activeDevice, lastSyncedAt: localCache.state.lastSyncedAt)

            PendingTabCloseStrip(tracked: trackedCloses) { close in
                pendingCloses.removeAll { $0.tabID == close.tabID }
            }
            .animation(.easeInOut(duration: 0.2), value: trackedCloses)

            if !searchText.isEmpty {
                combinedSearchResultsView
            } else {
                tabListMainView
            }
        }
        .searchable(text: $searchText, prompt: "Search tabs, bookmarks, history…")
        .onChange(of: localCache.state.tabs.count) {
            pruneFinishedCloses()
        }
        .fullScreenCover(item: $selectedURLForReader) { url in
            InAppBrowserView(url: url)
                .ignoresSafeArea()
        }
        .sheet(item: $tabSaveRequest) { request in
            BookmarkMovePicker(sourceDeviceID: request.tab.deviceID, title: "Save to…") { destination in
                saveTabAsBookmark(request.tab, to: destination)
            }
        }
        .overlay(alignment: .bottom) {
            if showToast, let toastMessage {
                Text(toastMessage)
                    .font(.subheadline.weight(.medium))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(.ultraThinMaterial)
                    // Capsule outside 16pt horizontal padding, so the text
                    // never sits on the curve.
                    .clipShape(Capsule())
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    @ViewBuilder
    private var tabListMainView: some View {
        VStack(spacing: 0) {
            Picker("Sort", selection: $sortMode) {
                ForEach(TabSortMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            if visibleTabs.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "macwindow.on.rectangle")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No Open Tabs")
                        .font(.headline)
                    Text("Open tabs on your Mac browsers will sync here automatically.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    switch sortMode {
                    case .recent:
                        ForEach(visibleTabs) { tab in
                            tabRow(tab)
                        }
                    case .domain:
                        ForEach(tabsByDomain) { group in
                            Section(header: HStack {
                                Text(group.domain)
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Text("\(group.tabs.count)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }) {
                                ForEach(group.tabs) { tab in
                                    tabRow(tab)
                                }
                            }
                        }
                    case .windows:
                        ForEach(tabsByBrowserAndWindow) { group in
                            Section(header: HStack {
                                Text(group.browser)
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(group.window)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }) {
                                ForEach(group.tabs) { tab in
                                    tabRow(tab)
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
    }

    @ViewBuilder
    private var combinedSearchResultsView: some View {
        if matchingTabs.isEmpty && matchingBookmarks.isEmpty && matchingHistory.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("No Matches for \"\(searchText)\"")
                    .font(.headline)
                Text("Check spelling or broaden your search keywords.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                if !matchingTabs.isEmpty {
                    Section(header: HStack {
                        Text("Open Tabs")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(matchingTabs.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }) {
                        ForEach(matchingTabs) { tab in
                            tabRow(tab, showTypeTag: "Tab")
                        }
                    }
                }

                if !matchingBookmarks.isEmpty {
                    Section(header: HStack {
                        Text("Bookmarks")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(matchingBookmarks.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }) {
                        ForEach(matchingBookmarks, id: \.item.id) { entry in
                            HStack(spacing: 10) {
                                Image(systemName: "bookmark.fill")
                                    .foregroundStyle(.yellow)
                                    .font(.system(size: 14))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.item.title.isEmpty ? entry.item.url : entry.item.title)
                                        .font(.body)
                                        .lineLimit(1)

                                    HStack(spacing: 6) {
                                        if let folder = entry.item.folderPath, !folder.isEmpty {
                                            Text(folder)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                        Text(entry.item.url)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if let url = URL(string: entry.item.url) {
                                    selectedURLForReader = url
                                }
                            }
                        }
                    }
                }

                if !matchingHistory.isEmpty {
                    Section(header: HStack {
                        Text("Recent History")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(matchingHistory.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }) {
                        ForEach(matchingHistory, id: \.entry.id) { item in
                            HStack(spacing: 10) {
                                Image(systemName: "clock")
                                    .foregroundStyle(.secondary)
                                    .font(.system(size: 14))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.entry.title.isEmpty ? item.entry.url : item.entry.title)
                                        .font(.body)
                                        .lineLimit(1)

                                    Text(item.entry.url)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if let url = URL(string: item.entry.url) {
                                    selectedURLForReader = url
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    @ViewBuilder
    private func tabRow(_ tab: SyncedTab, showTypeTag: String? = nil) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "globe")
                .foregroundStyle(Color.accentColor)
                .font(.system(size: 16))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(tab.title.isEmpty ? tab.url : tab.title)
                        .font(.body)
                        .lineLimit(1)

                    if tab.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }

                    if tab.isAudible {
                        Image(systemName: tab.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.caption2)
                            .foregroundStyle(.purple)
                    }
                }

                HStack(spacing: 6) {
                    Text(tab.browserName)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)

                    Text("•")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Text(URL(string: tab.url)?.host() ?? tab.url)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let url = URL(string: tab.url) {
                selectedURLForReader = url
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                requestClose(of: tab)
            } label: {
                Label("Close", systemImage: "xmark")
            }
        }
        .swipeActions(edge: .leading) {
            Button {
                tabSaveRequest = TabSaveRequest(tab: tab)
            } label: {
                Label("Save to Folder", systemImage: "folder")
            }
            .tint(.blue)

            Button {
                UIPasteboard.general.string = tab.url
                showToastHUD(message: "URL Copied")
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .tint(.blue)
        }
        .contextMenu {
            if let url = URL(string: tab.url) {
                Button {
                    selectedURLForReader = url
                } label: {
                    Label("Open in Reader", systemImage: "doc.plaintext")
                }

                Link(destination: url) {
                    Label("Open in Safari", systemImage: "safari")
                }

                Button {
                    UIPasteboard.general.string = tab.url
                    showToastHUD(message: "URL Copied")
                } label: {
                    Label("Copy URL", systemImage: "doc.on.doc")
                }

                Button {
                    tabSaveRequest = TabSaveRequest(tab: tab)
                } label: {
                    Label("Save to Folder", systemImage: "folder")
                }

                Divider()

                Button(role: .destructive) {
                    requestClose(of: tab)
                } label: {
                    Label("Close Tab on Mac", systemImage: "xmark.circle")
                }
            }
        }
    }

    /// Asks the Mac to close a tab, and hides the row only for as long as that
    /// request is genuinely travelling or genuinely done.
    ///
    /// `SyncConsumer.sendCloseTab` returns nothing, so the issued command is
    /// identified by diffing the recorded-command list around the call. Both
    /// sides are on the main actor and the recording is synchronous, so exactly
    /// one new command can appear — or none, when the payload could not be
    /// encoded, which is why the row is never hidden before an id is in hand.
    private func requestClose(of tab: SyncedTab) {
        let knownCommandIDs = Set(localCache.state.sentCommands.map(\.id))
        SyncConsumer.shared.sendCloseTab(tab)

        guard let issued = localCache.state.sentCommands.first(where: { !knownCommandIDs.contains($0.id) }) else {
            showToastHUD(message: "Couldn't queue that close — the tab is still open")
            return
        }

        withAnimation(.easeInOut(duration: 0.2)) {
            pendingCloses.removeAll { $0.tabID == tab.id }
            pendingCloses.append(PendingTabClose(
                tabID: tab.id,
                commandID: issued.id,
                tabTitle: Self.displayTitle(for: tab)
            ))
        }
        showToastHUD(message: closeAcknowledgement)
    }

    /// The only thing that is true the instant the request is made: it is
    /// written down on this phone, and it has not reached the Mac yet.
    private var closeAcknowledgement: String {
        if SyncConsumer.shared.syncHealth.isBlocked {
            return "Saved on this iPhone — sync is off, so your Mac hasn't been told"
        }
        return "Close queued for \(activeDevice?.name ?? "your Mac")"
    }

    /// Asks the tab's Mac to save the tab's URL as a new bookmark into the
    /// picked folder. Unlike the bookmark-tree Move (which relocates an existing
    /// bookmark), there is no source node to remove — the tab stays open and a
    /// new bookmark is inserted. Runs immediately on the Mac, no approval step.
    private func saveTabAsBookmark(_ tab: SyncedTab, to destination: BookmarkMoveDestination) {
        SyncConsumer.shared.sendAddBookmark(
            title: Self.displayTitle(for: tab),
            url: tab.url,
            destinationBrowserName: destination.browserName,
            destinationProfileName: destination.profileName,
            destinationFolderPath: destination.folderPath,
            targetDeviceID: tab.deviceID
        )
        showToastHUD(message: saveAcknowledgement(for: tab))
    }

    private func saveAcknowledgement(for tab: SyncedTab) -> String {
        if SyncConsumer.shared.syncHealth.isBlocked {
            return "Saved on this iPhone — sync is off, so your Mac hasn't been told"
        }
        let deviceName = localCache.state.devices.first { $0.id == tab.deviceID }?.name ?? "your Mac"
        return "Save queued for \(deviceName)"
    }

    private static func displayTitle(for tab: SyncedTab) -> String {
        if !tab.title.isEmpty { return tab.title }
        return URL(string: tab.url)?.host() ?? tab.url
    }

    private func showToastHUD(message: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            toastMessage = message
            showToast = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation(.easeInOut(duration: 0.2)) {
                showToast = false
            }
        }
    }
}
