import SwiftUI
import FastTabSync

public struct EmergingTopicsView: View {
    @ObservedObject var service = IntelligenceService.shared
    @ObservedObject var localCache = LocalCache.shared

    @State private var selectedURLForReader: URL?
    @State private var clusterToSave: TopicCluster?
    @State private var showCustomFolderPicker: Bool = false
    @State private var toastMessage: String?
    @State private var showToast: Bool = false

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
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.3)
                    Text("Analyzing your browsing activity…")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Connecting open tabs, history, and bookmarks into emerging topics.")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if service.topicClusters.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 44))
                        .foregroundStyle(.purple.opacity(0.8))
                    Text("No Emerging Topics Yet")
                        .font(.title3.weight(.semibold))
                    Text("Browse more pages or open tabs on your Mac to let Intelligence group your recent activity into connected thoughts.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    
                    Button {
                        service.analyze(force: true)
                    } label: {
                        Label("Analyze Now", systemImage: "arrow.clockwise")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .padding(.top, 6)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 20) {
                        ForEach(service.topicClusters) { cluster in
                            TopicClusterCard(
                                cluster: cluster,
                                onSelectURL: { url in
                                    selectedURLForReader = url
                                },
                                onSaveAll: {
                                    clusterToSave = cluster
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 80) // Spacing for floating sub-tab bar
                }
                .refreshable {
                    service.analyze(force: true)
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: service.topicClusters.isEmpty)
        .animation(.easeInOut(duration: 0.25), value: service.isProcessing)
        .sheet(item: $selectedURLForReader) { url in
            InAppBrowserView(url: url)
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
        .overlay(alignment: .bottom) {
            if showToast, let toastMessage {
                Text(toastMessage)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.black.opacity(0.82)))
                    .shadow(radius: 8)
                    .padding(.bottom, 75)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
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

// MARK: - Topic Cluster Card

struct TopicClusterCard: View {
    let cluster: TopicCluster
    let onSelectURL: (URL) -> Void
    let onSaveAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(cluster.name)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.primary)

                    if let summary = cluster.summary {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Button(action: onSaveAll) {
                    HStack(spacing: 4) {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Save All")
                            .font(.subheadline.weight(.semibold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.purple.opacity(0.12))
                    .foregroundStyle(.purple)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            Divider()

            // Recent Browsing Items Section
            VStack(alignment: .leading, spacing: 8) {
                ForEach(cluster.recentItems) { item in
                    Button {
                        if let url = URL(string: item.url) {
                            onSelectURL(url)
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: item.source.isTab ? "macwindow" : "clock.arrow.circlepath")
                                .font(.system(size: 14))
                                .foregroundStyle(item.source.isTab ? .blue : .orange)
                                .frame(width: 20)

                            VStack(alignment: .leading, spacing: 2) {
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
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            // Related Bookmarks Section
            if !cluster.relatedBookmarks.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 5) {
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.yellow)
                        Text("From your bookmarks")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)

                    ForEach(cluster.relatedBookmarks) { bm in
                        Button {
                            if let url = URL(string: bm.url) {
                                onSelectURL(url)
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "bookmark")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.yellow)
                                    .frame(width: 20)

                                VStack(alignment: .leading, spacing: 2) {
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
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: Color.black.opacity(0.04), radius: 8, x: 0, y: 2)
    }
}
