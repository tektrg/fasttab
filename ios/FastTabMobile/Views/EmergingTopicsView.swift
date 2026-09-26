import SwiftUI
import FastTabSync

public struct EmergingTopicsView: View {
    @ObservedObject var service = IntelligenceService.shared
    @ObservedObject var localCache = LocalCache.shared

    @State private var selectedURLForReader: URL?
    @State private var readerItem: ReaderNavigationItem?
    @State private var clusterToSave: TopicCluster?
    @State private var showCustomFolderPicker: Bool = false
    @State private var toast: String?

    public init() {}

    private var activeDeviceID: String {
        localCache.state.devices.first?.id ?? ""
    }

    private var defaultBrowserName: String {
        let matchingBlob = localCache.state.bookmarkBlobs.first(where: {
            $0.deviceID == activeDeviceID && !$0.browserName.lowercased().contains("safari")
        }) ?? localCache.state.bookmarkBlobs.first(where: { !$0.browserName.lowercased().contains("safari") })
        return matchingBlob?.browserName ?? "Google Chrome"
    }

    private var defaultProfileName: String {
        let matchingBlob = localCache.state.bookmarkBlobs.first(where: {
            $0.deviceID == activeDeviceID && !$0.browserName.lowercased().contains("safari")
        }) ?? localCache.state.bookmarkBlobs.first(where: { !$0.browserName.lowercased().contains("safari") })
        return matchingBlob?.profileName ?? "Default"
    }

    public var body: some View {
        Group {
            if service.isProcessing && service.topicClusters.isEmpty {
                VStack(spacing: DS.Space.lg) {
                    ProgressView()
                        .scaleEffect(1.3)
                    Text("Analyzing your browsing activity…")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Connecting open tabs, history, and bookmarks into emerging topics.")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, DS.Space.xxl)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if service.topicClusters.isEmpty {
                DSEmptyState(
                    "No Emerging Topics Yet",
                    systemImage: "sparkles",
                    message: "Browse more pages or open tabs on your Mac to let Intelligence group your recent activity into connected thoughts.",
                    tint: DS.Tint.emerging
                ) {
                    Button {
                        service.analyze(force: true)
                    } label: {
                        Label("Analyze Now", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.dsPrimary(DS.Tint.emerging))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: DS.Space.section) {
                        ForEach(service.topicClusters) { cluster in
                            TopicClusterCard(
                                cluster: cluster,
                                onSelectURL: { url in
                                    selectedURLForReader = url
                                },
                                onOpenInReader: { url, title in
                                    readerItem = ReaderNavigationItem(url: url, title: title)
                                },
                                onSaveAll: {
                                    clusterToSave = cluster
                                }
                            )
                        }
                    }
                    .padding(.horizontal, DS.Space.gutter)
                    .padding(.top, DS.Space.md)
                    .padding(.bottom, DS.Space.floatingBarClearance + DS.Space.sm) // Spacing for floating sub-tab bar
                }
                .refreshable {
                    service.analyze(force: true)
                }
            }
        }
        .dsCanvas()
        .animation(.easeInOut(duration: 0.25), value: service.topicClusters.isEmpty)
        .animation(.easeInOut(duration: 0.25), value: service.isProcessing)
        .sheet(item: $selectedURLForReader) { url in
            InAppBrowserView(url: url)
        }
        .fullScreenCover(item: $readerItem) { item in
            ReaderView(url: item.url, title: item.title, focusHighlightID: item.focusHighlightID)
        }
        .confirmationDialog(
            "Save Topic to Bookmarks",
            isPresented: Binding(
                get: { clusterToSave != nil && !showCustomFolderPicker },
                set: { if !$0 { clusterToSave = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let cluster = clusterToSave {
                Button("Create Folder \"\(cluster.suggestedFolderName)\"") {
                    saveClusterToDefaultFolder(cluster)
                }
                Button("Pick Existing Folder…") {
                    showCustomFolderPicker = true
                }
                Button("Cancel", role: .cancel) {
                    clusterToSave = nil
                }
            }
        } message: {
            if let cluster = clusterToSave {
                Text("Save \(cluster.recentItems.count) links from \"\(cluster.name)\" to your Mac's browser bookmarks.")
            }
        }
        .sheet(isPresented: $showCustomFolderPicker) {
            if let cluster = clusterToSave {
                BookmarkMovePicker(
                    sourceDeviceID: activeDeviceID,
                    title: "Save \"\(cluster.name)\" to…"
                ) { destination in
                    service.saveClusterToFolder(
                        cluster: cluster,
                        folderPath: destination.folderPath + [cluster.suggestedFolderName],
                        targetDeviceID: activeDeviceID,
                        browserName: destination.browserName,
                        profileName: destination.profileName
                    )
                    showToastHUD(message: "Saved \(cluster.recentItems.count) links to \(destination.folderDisplayName)")
                    clusterToSave = nil
                    showCustomFolderPicker = false
                }
            }
        }
        .dsToast($toast, bottomInset: DS.Space.floatingBarClearance)
    }

    private func saveClusterToDefaultFolder(_ cluster: TopicCluster) {
        guard !activeDeviceID.isEmpty else {
            showToastHUD(message: "No connected Mac found")
            return
        }
        service.saveClusterToFolder(
            cluster: cluster,
            folderPath: ["Intelligence", cluster.suggestedFolderName],
            targetDeviceID: activeDeviceID,
            browserName: defaultBrowserName,
            profileName: defaultProfileName
        )
        showToastHUD(message: "Saved \(cluster.recentItems.count) links to \"Intelligence / \(cluster.suggestedFolderName)\"")
        clusterToSave = nil
    }

    private func showToastHUD(message: String) {
        toast = message
    }
}

// MARK: - Topic Cluster Card

struct TopicClusterCard: View {
    let cluster: TopicCluster
    let onSelectURL: (URL) -> Void
    let onOpenInReader: (URL, String) -> Void
    let onSaveAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            // Header
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text(cluster.name)
                        .font(DS.Font.sectionTitle)
                        .foregroundStyle(.primary)

                    if let summary = cluster.summary {
                        Text(summary)
                            .font(DS.Font.meta)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Button(action: onSaveAll) {
                    HStack(spacing: DS.Space.xs) {
                        Image(systemName: "folder.badge.plus")
                        Text("Save All")
                    }
                }
                .buttonStyle(.dsTinted(DS.Tint.emerging))
            }

            Divider()

            // Recent Browsing Items Section
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                ForEach(cluster.recentItems) { item in
                    Button {
                        if let url = URL(string: item.url) {
                            onSelectURL(url)
                        }
                    } label: {
                        HStack(spacing: DS.Space.md) {
                            Image(systemName: item.source.isTab ? "macwindow" : "clock.arrow.circlepath")
                                .font(.system(size: 14))
                                .foregroundStyle(item.source.isTab ? DS.Tint.action : .secondary)
                                .frame(width: 20)

                            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                                Text(item.displayTitle)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)

                                HStack(spacing: 6) {
                                    Text(item.source.badgeLabel)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)

                                    Text("•")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)

                                    Text(item.host)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
                            }

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, DS.Space.xs)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if let url = URL(string: item.url) {
                            Button {
                                onOpenInReader(url, item.displayTitle)
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
                            } label: {
                                Label("Copy URL", systemImage: "doc.on.doc")
                            }

                            Button {
                                SyncConsumer.shared.sendOpenOnMac(url: item.url, title: item.displayTitle)
                            } label: {
                                Label("Open on Mac", systemImage: "laptopcomputer")
                            }
                        }
                    }
                }
            }

            // Related Bookmarks Section
            if !cluster.relatedBookmarks.isEmpty {
                VStack(alignment: .leading, spacing: DS.Space.sm) {
                    HStack(spacing: DS.Space.xs) {
                        Image(systemName: "bookmark.fill")
                            .imageScale(.small)
                            .foregroundStyle(DS.Tint.bookmark)
                        Text("From your bookmarks")
                            .foregroundStyle(.secondary)
                    }
                    .font(DS.Font.meta.weight(.semibold))
                    .padding(.top, DS.Space.xs)

                    ForEach(cluster.relatedBookmarks) { bm in
                        Button {
                            if let url = URL(string: bm.url) {
                                onSelectURL(url)
                            }
                        } label: {
                            HStack(spacing: DS.Space.md) {
                                Image(systemName: "bookmark")
                                    .font(.system(size: 13))
                                    .foregroundStyle(DS.Tint.bookmark)
                                    .frame(width: 20)

                                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                                    Text(bm.displayTitle)
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)

                                    Text(bm.folderDisplayName)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer()

                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, DS.Space.xxs)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if let url = URL(string: bm.url) {
                                Button {
                                    onOpenInReader(url, bm.displayTitle)
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
                                    UIPasteboard.general.string = bm.url
                                } label: {
                                    Label("Copy URL", systemImage: "doc.on.doc")
                                }

                                Button {
                                    SyncConsumer.shared.sendOpenOnMac(url: bm.url, title: bm.displayTitle)
                                } label: {
                                    Label("Open on Mac", systemImage: "laptopcomputer")
                                }
                            }
                        }
                    }
                }
                .padding(.top, DS.Space.xs)
            }
        }
        .dsCard()
    }
}
