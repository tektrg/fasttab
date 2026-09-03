import SwiftUI
import FastTabSync

/// Where a bookmark move should land: a browser+profile (same Mac as the
/// source) and a folder path within it. `folderPath: []` means "top level".
struct BookmarkMoveDestination: Equatable {
    let browserName: String
    let profileName: String
    let folderPath: [String]

    var folderDisplayName: String {
        folderPath.isEmpty ? "Top Level" : folderPath.joined(separator: " / ")
    }
}

/// Which destinations the move picker should hide: the folder/bookmark's
/// *current home*, so you can't "move" something to where it already is (a
/// no-op the Mac would still churn through). Scoped by (browser, profile) —
/// the same path in a *different* profile is a perfectly valid destination, and
/// only whole-folder moves also hide nested paths (you can't move a folder into
/// itself or a subfolder) and the direct parent (a silent no-op).
struct FolderMoveExclusion {
    let path: [String]
    /// "\(browserName)|\(profileName)" pairs where `path` is the current home.
    let profileKeys: Set<String>
    /// Folder moves hide subpaths of `path`; bookmark moves only hide `path`.
    let includeSubpaths: Bool
}

/// One-screen destination picker for "Move": search folders across every
/// profile, jump straight to a Frequent/Recent shortcut, or browse profile by
/// profile. Only lists profiles/folders that already have at least one synced
/// bookmark today (a known, accepted v1 limitation) and only profiles on the
/// *same* Mac the bookmark (or folder) is already on — moving across Macs
/// would need two separate network round-trips with no way to roll back a
/// partial failure, so it's out of scope (see the move-bookmark plan).
///
/// Originally a two-step profile-then-folder drill-down. Collapsed into one
/// screen so search can span every profile at once and Frequent/Recent
/// shortcuts land on the same screen the user opens first — see the
/// move-picker-upgrade plan.
///
/// Scoped by `sourceDeviceID` rather than a source node, because a *folder*
/// being moved has no `BookmarkSource` of its own — its leaves do. When moving,
/// `folderMoveExclusion` keeps the folder/bookmark's current home off the
/// destination list (so you can't "move" something to where it already is).
struct BookmarkMovePicker: View {
    @ObservedObject private var localCache = LocalCache.shared
    @Environment(\.dismiss) private var dismiss

    let sourceDeviceID: String
    var folderMoveExclusion: FolderMoveExclusion? = nil
    /// Sheet title. "Move to…" when relocating a bookmark (the tree's default),
    /// "Save to…" when a tab is being saved as a new bookmark (nothing moves).
    var title: String = "Move to…"
    let onConfirm: (BookmarkMoveDestination) -> Void

    @State private var searchText: String = ""
    @State private var newFolderContext: NewFolderContext? = nil

    private struct NewFolderContext: Identifiable {
        let id = UUID()
        var profileKey: String? = nil
        var parentPath: [String] = []
    }

    private static let pinnedShortcutCount = 3

    /// One selectable destination: a profile plus a folder path inside it
    /// (`[]` = that profile's top level).
    private struct FolderOption: Identifiable, Hashable {
        let browserName: String
        let profileName: String
        let folderPath: [String]

        var id: String { "\(browserName)|\(profileName)|\(folderPath.joined(separator: "/"))" }
        var profileDisplayName: String { "\(browserName) — \(profileName)" }
        var folderDisplayName: String { folderPath.isEmpty ? "Top Level" : folderPath.joined(separator: " / ") }
        var iconName: String { folderPath.isEmpty ? "tray" : "folder" }
        var searchableText: String { "\(folderDisplayName) \(profileDisplayName)".lowercased() }

        static func sortKey(_ option: FolderOption) -> String {
            "\(option.profileDisplayName)|\(option.folderPath.isEmpty ? "" : "1")|\(option.folderDisplayName)"
        }
    }

    private struct ProfileGroup: Identifiable {
        let profileDisplayName: String
        let folders: [FolderOption]
        var id: String { profileDisplayName }
    }

    /// Same-device, non-Safari profiles that currently have at least one
    /// synced bookmark, expanded into every distinct folder path in each
    /// (plus a synthesized "Top Level" per profile). `SyncedBookmarkItem
    /// .folderPath` is parsed with the existing `BookmarkTreeBuilder
    /// .splitPath` — no new tree-walking logic needed.
    private var allFolderOptions: [FolderOption] {
        guard !sourceDeviceID.isEmpty else { return [] }
        let blobs = localCache.state.bookmarkBlobs.filter {
            $0.deviceID == sourceDeviceID
                && !$0.browserName.lowercased().contains("safari")
                && !$0.bookmarks.isEmpty
        }

        var pathsByProfile: [String: (browserName: String, profileName: String, paths: Set<[String]>)] = [:]
        for blob in blobs {
            let key = "\(blob.browserName)|\(blob.profileName)"
            var entry = pathsByProfile[key] ?? (blob.browserName, blob.profileName, [[]])
            for bookmark in blob.bookmarks {
                let path = BookmarkTreeBuilder.splitPath(bookmark.folderPath ?? "")
                if !path.isEmpty {
                    for i in 1...path.count {
                        entry.paths.insert(Array(path.prefix(i)))
                    }
                }
            }
            pathsByProfile[key] = entry
        }

        return pathsByProfile.values.flatMap { entry in
            entry.paths.map { FolderOption(browserName: entry.browserName, profileName: entry.profileName, folderPath: $0) }
        }
        .filter { option in
            // Hide destinations that are the moved thing's current home — the
            // folder's own path and (for folder moves) its subpaths and direct
            // parent. Scoped by profile so a same-named folder in a different
            // profile stays a valid destination.
            guard let exclusion = folderMoveExclusion else { return true }
            let key = "\(option.browserName)|\(option.profileName)"
            guard exclusion.profileKeys.contains(key) else { return true }
            if option.folderPath == exclusion.path { return false }
            guard exclusion.includeSubpaths else { return true }
            if option.folderPath.starts(with: exclusion.path) { return false }
            if option.folderPath == Array(exclusion.path.dropLast()) { return false }
            return true
        }
    }

    private var optionsByID: [String: FolderOption] {
        Dictionary(uniqueKeysWithValues: allFolderOptions.map { ($0.id, $0) })
    }

    private func recordID(_ record: BookmarkMoveDestinationRecord) -> String {
        "\(record.browserName)|\(record.profileName)|\(record.folderPath.joined(separator: "/"))"
    }

    /// Drops any pinned destination that no longer qualifies (its profile
    /// went empty, etc.) rather than offering a shortcut the move would refuse.
    private var frequentOptions: [FolderOption] {
        guard !sourceDeviceID.isEmpty else { return [] }
        let byID = optionsByID
        return BookmarkMoveDestinationHistory.topFrequent(deviceID: sourceDeviceID, limit: Self.pinnedShortcutCount)
            .compactMap { byID[recordID($0)] }
    }

    private var recentOptions: [FolderOption] {
        guard !sourceDeviceID.isEmpty else { return [] }
        let byID = optionsByID
        return BookmarkMoveDestinationHistory.topRecent(deviceID: sourceDeviceID, limit: Self.pinnedShortcutCount)
            .compactMap { byID[recordID($0)] }
    }

    /// "The rest" — everything not already offered as a Frequent/Recent
    /// shortcut, so a folder never shows up two or three times on one screen.
    private var profileGroups: [ProfileGroup] {
        let pinnedIDs = Set(frequentOptions.map(\.id)).union(recentOptions.map(\.id))
        let grouped = Dictionary(grouping: allFolderOptions.filter { !pinnedIDs.contains($0.id) }, by: \.profileDisplayName)
        return grouped.keys
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { name in
                let folders = (grouped[name] ?? []).sorted {
                    FolderOption.sortKey($0).localizedCaseInsensitiveCompare(FolderOption.sortKey($1)) == .orderedAscending
                }
                return ProfileGroup(profileDisplayName: name, folders: folders)
            }
    }

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Folder name *or* profile name matching — this is the "search across
    /// every profile at once" behavior, rather than only searching within a
    /// profile the user already drilled into.
    private var searchResults: [FolderOption] {
        let query = trimmedSearchText.lowercased()
        guard !query.isEmpty else { return [] }
        return allFolderOptions
            .filter { $0.searchableText.contains(query) }
            .sorted { FolderOption.sortKey($0).localizedCaseInsensitiveCompare(FolderOption.sortKey($1)) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List {
                if !trimmedSearchText.isEmpty {
                    Section("Results") {
                        ForEach(searchResults) { option in
                            folderRow(option, showsProfile: true)
                        }
                    }
                } else {
                    if !frequentOptions.isEmpty {
                        Section("Frequent") {
                            ForEach(frequentOptions) { option in
                                folderRow(option, showsProfile: true)
                            }
                        }
                    }
                    if !recentOptions.isEmpty {
                        Section("Recent") {
                            ForEach(recentOptions) { option in
                                folderRow(option, showsProfile: true)
                            }
                        }
                    }
                    ForEach(profileGroups) { group in
                        Section {
                            ForEach(group.folders) { option in
                                folderRow(option, showsProfile: false)
                            }
                        } header: {
                            HStack {
                                Text(group.profileDisplayName)
                                Spacer()
                                Button {
                                    let profileKey = group.folders.first.map { "\($0.browserName)|\($0.profileName)" }
                                    newFolderContext = NewFolderContext(profileKey: profileKey, parentPath: [])
                                } label: {
                                    Label("New Folder", systemImage: "folder.badge.plus")
                                        .labelStyle(.iconOnly)
                                        .font(.caption)
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.blue)
                            }
                        }
                    }
                }
            }
            .overlay {
                if allFolderOptions.isEmpty {
                    ContentUnavailableView(
                        "No Destinations Yet",
                        systemImage: "folder.badge.questionmark",
                        description: Text("Only profiles that already have a synced bookmark can be picked as a destination.")
                    )
                } else if !trimmedSearchText.isEmpty && searchResults.isEmpty {
                    ContentUnavailableView.search(text: trimmedSearchText)
                }
            }
            .searchable(text: $searchText, prompt: "Search folders across profiles")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        newFolderContext = NewFolderContext()
                    } label: {
                        Label("New Folder", systemImage: "folder.badge.plus")
                    }
                }
            }
            .sheet(item: $newFolderContext) { context in
                NewBookmarkFolderSheet(
                    sourceDeviceID: sourceDeviceID,
                    initialProfileKey: context.profileKey,
                    initialParentPath: context.parentPath
                ) { browserName, profileName, folderName, parentFolderPath in
                    let fullPath = parentFolderPath + [folderName]
                    LocalCache.shared.registerCreatedFolder(
                        browserName: browserName,
                        profileName: profileName,
                        folderPath: fullPath,
                        deviceID: sourceDeviceID
                    )
                    SyncConsumer.shared.sendCreateFolder(
                        name: folderName,
                        parentFolderPath: parentFolderPath,
                        browserName: browserName,
                        profileName: profileName,
                        targetDeviceID: sourceDeviceID
                    )
                    confirm(FolderOption(browserName: browserName, profileName: profileName, folderPath: fullPath))
                }
            }
        }
    }

    @ViewBuilder
    private func folderRow(_ option: FolderOption, showsProfile: Bool) -> some View {
        Button {
            confirm(option)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: option.iconName)
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.folderDisplayName)
                        .foregroundStyle(.primary)
                    if showsProfile {
                        Text(option.profileDisplayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                newFolderContext = NewFolderContext(
                    profileKey: "\(option.browserName)|\(option.profileName)",
                    parentPath: option.folderPath
                )
            } label: {
                Label("Add Subfolder", systemImage: "folder.badge.plus")
            }
            .tint(.blue)
        }
        .contextMenu {
            Button {
                newFolderContext = NewFolderContext(
                    profileKey: "\(option.browserName)|\(option.profileName)",
                    parentPath: option.folderPath
                )
            } label: {
                Label("Add Subfolder…", systemImage: "folder.badge.plus")
            }
        }
    }

    private func confirm(_ option: FolderOption) {
        guard !sourceDeviceID.isEmpty else { return }
        BookmarkMoveDestinationHistory.recordSelection(
            deviceID: sourceDeviceID,
            browserName: option.browserName,
            profileName: option.profileName,
            folderPath: option.folderPath
        )
        onConfirm(BookmarkMoveDestination(
            browserName: option.browserName,
            profileName: option.profileName,
            folderPath: option.folderPath
        ))
        dismiss()
    }
}
