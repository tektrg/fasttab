import Foundation
import SwiftUI
import Combine
import OSLog
import FastTabSync

public enum RecentAddedSource: Hashable, Sendable {
    case shareSheet(commandID: String, status: String)
    case bookmark(
        browser: String,
        folderPath: String?,
        bookmark: SyncedBookmarkItem,
        profileName: String?,
        deviceID: String
    )

    public var badgeText: String {
        switch self {
        case .shareSheet(_, let status):
            return status.isEmpty ? "Queued to Mac" : status
        case .bookmark(_, let folder, _, _, _):
            if let folder, !folder.isEmpty {
                return BookmarkTreeBuilder.splitPath(folder).last ?? folder
            }
            return "Bookmark"
        }
    }

    public var iconName: String {
        switch self {
        case .shareSheet: return "paperplane.fill"
        case .bookmark: return "bookmark.fill"
        }
    }

    public var tintColor: Color {
        switch self {
        case .shareSheet: return DS.Tint.shared
        case .bookmark: return DS.Tint.bookmark
        }
    }
}

public struct BookmarkFolderChip: Identifiable, Hashable, Sendable {
    public var id: String { fullPath }
    public let fullPath: String
    public let displayName: String

    public init(fullPath: String, displayName: String) {
        self.fullPath = fullPath
        self.displayName = displayName
    }
}

public struct RecentAddedItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let url: URL
    public let domain: String
    public let date: Date
    public let source: RecentAddedSource
    public let folderPath: String?

    public init(
        id: String,
        title: String,
        url: URL,
        domain: String,
        date: Date,
        source: RecentAddedSource,
        folderPath: String? = nil
    ) {
        self.id = id
        self.title = title.isEmpty ? domain : title
        self.url = url
        self.domain = domain
        self.date = date
        self.source = source
        self.folderPath = folderPath
    }
}

@MainActor
public final class RecentAddedProvider: ObservableObject {
    public static let shared = RecentAddedProvider()

    @Published public private(set) var items: [RecentAddedItem] = []
    @Published public private(set) var availableFolders: [BookmarkFolderChip] = []

    private let logger = Logger(subsystem: "app.theindie.FastTab", category: "RecentAddedProvider")
    private var stateCancellable: AnyCancellable?

    private init() {
        drainPendingShares()
        refresh()

        // Re-seed automatically whenever LocalCache updates from background sync or foreground polling
        stateCancellable = LocalCache.shared.$state
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
    }

    /// Drains any pending share sheet files left in the AppGroup directory by `ShareViewController`.
    public func drainPendingShares() {
        let groupURL = AppGroupContainer.directoryURL
        let pendingDir = groupURL.appendingPathComponent("pending_shares", isDirectory: true)

        guard FileManager.default.fileExists(atPath: pendingDir.path) else { return }

        do {
            let files = try FileManager.default.contentsOfDirectory(at: pendingDir, includingPropertiesForKeys: nil)
            for file in files where file.pathExtension == "json" {
                if let data = try? Data(contentsOf: file),
                   let command = try? JSONDecoder().decode(SyncCommand.self, from: data) {
                    LocalCache.shared.recordSentCommand(command)
                    logger.info("Ingested pending share command: \(command.id, privacy: .public)")
                }
                try? FileManager.default.removeItem(at: file)
            }
        } catch {
            logger.error("Failed to drain pending_shares: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Rebuilds the combined list of recent bookmarks and desk queue / share sheet additions.
    public func refresh() {
        drainPendingShares()

        let state = LocalCache.shared.state
        var gathered: [RecentAddedItem] = []
        var seenNormalizedURLs = Set<String>()

        // 1. Ingest Share Sheet / Desk Queue items (.openOnMac commands)
        for command in state.sentCommands where command.kind == .openOnMac {
            guard let data = command.payloadJSON.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(OpenOnMacPayload.self, from: data),
                  let url = URL(string: payload.url),
                  url.scheme?.hasPrefix("http") == true else {
                continue
            }

            let normalized = normalize(url)
            if !seenNormalizedURLs.contains(normalized) {
                seenNormalizedURLs.insert(normalized)
                let delivery = LocalCache.shared.delivery(forCommandID: command.id)
                let progress = CommandProgress.of(command: command, delivery: delivery)

                gathered.append(RecentAddedItem(
                    id: "share_\(command.id)",
                    title: payload.title ?? url.host() ?? payload.url,
                    url: url,
                    domain: url.host() ?? "",
                    date: command.issuedAt,
                    source: .shareSheet(commandID: command.id, status: progress.label),
                    folderPath: nil
                ))
            }
        }

        // 2. Ingest Synced Bookmarks
        var folderMap: [String: String] = [:] // fullPath -> displayName
        for blob in state.bookmarkBlobs {
            for bm in blob.bookmarks {
                guard let url = URL(string: bm.url), url.scheme?.hasPrefix("http") == true else { continue }
                if let folder = bm.folderPath, !folder.isEmpty {
                    let leafName = BookmarkTreeBuilder.splitPath(folder).last ?? folder
                    folderMap[folder] = leafName
                }

                let normalized = normalize(url)
                if !seenNormalizedURLs.contains(normalized) {
                    seenNormalizedURLs.insert(normalized)
                    gathered.append(RecentAddedItem(
                        id: "bm_\(blob.id)_\(bm.id)",
                        title: bm.title.isEmpty ? (url.host() ?? bm.url) : bm.title,
                        url: url,
                        domain: url.host() ?? "",
                        date: bm.dateAdded ?? blob.updatedAt,
                        source: .bookmark(
                            browser: blob.browserName,
                            folderPath: bm.folderPath,
                            bookmark: bm,
                            profileName: blob.profileName,
                            deviceID: blob.deviceID
                        ),
                        folderPath: bm.folderPath
                    ))
                }
            }
        }

        // Sort folder chips by display name
        self.availableFolders = folderMap.map { BookmarkFolderChip(fullPath: $0.key, displayName: $0.value) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

        // Sort newest first
        self.items = gathered.sorted { $0.date > $1.date }
    }

    public func removeItem(id: String) {
        items.removeAll { $0.id == id }
    }

    public func items(filteredByFolder folderPath: String?) -> [RecentAddedItem] {
        guard let folderPath, !folderPath.isEmpty else {
            return items
        }
        return items.filter { item in
            guard let itemFolder = item.folderPath else { return false }
            return itemFolder == folderPath || itemFolder.hasPrefix(folderPath + "/") || itemFolder.contains("/" + folderPath + "/") || itemFolder.hasSuffix("/" + folderPath)
        }
    }

    private func normalize(_ url: URL) -> String {
        let host = (url.host() ?? "").lowercased()
        let path = url.path().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let query = (url.query() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            return "\(host)/\(path)".lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        } else {
            return "\(host)/\(path)?\(query)".lowercased()
        }
    }
}
