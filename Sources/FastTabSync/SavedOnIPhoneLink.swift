import Foundation

/// One entry in the **FastTab List** — the user's read-later list (product name;
/// the Swift type keeps its older "Saved on iPhone" name). Distinct from browser
/// Bookmarks, which are browser-owned. Synced across devices through `ReaderZone`
/// (`FastTabListSyncBridge`; per-field merge in `FastTabListMerge`):
/// - `id` is derived from the canonical URL by the store, so the same link saved on
///   two devices becomes the same item.
/// - `deletedAt` is a tombstone: set = in Trash (purged after 30 days), nil = live.
/// - `readAt` / `progress` carry read state; each change bumps `updatedAt`
///   (`progressUpdatedAt` for progress) so a later merge can pick the newest.
///
/// The share extension writes these to `pending_saves` with a throwaway UUID id;
/// the app re-keys them on ingest. Decoding tolerates missing phase-1 fields so old
/// saves and old pending files still load.
public struct SavedOnIPhoneLink: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var url: String
    public var title: String?
    public var savedAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var readAt: Date?
    /// Scroll fraction 0...1 of the reader.
    public var progress: Double
    public var progressUpdatedAt: Date?
    /// When `readAt` last changed (set or cleared). Nil on items from before sync.
    public var readStateUpdatedAt: Date?

    public var isTrashed: Bool { deletedAt != nil }
    public var isRead: Bool { readAt != nil }

    public init(
        id: String = UUID().uuidString,
        url: String,
        title: String? = nil,
        savedAt: Date = Date(),
        updatedAt: Date? = nil,
        deletedAt: Date? = nil,
        readAt: Date? = nil,
        progress: Double = 0,
        progressUpdatedAt: Date? = nil,
        readStateUpdatedAt: Date? = nil
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.savedAt = savedAt
        self.updatedAt = updatedAt ?? savedAt
        self.deletedAt = deletedAt
        self.readAt = readAt
        self.progress = progress
        self.progressUpdatedAt = progressUpdatedAt
        self.readStateUpdatedAt = readStateUpdatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, url, title, savedAt, updatedAt, deletedAt, readAt, progress, progressUpdatedAt, readStateUpdatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        url = try c.decode(String.self, forKey: .url)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        savedAt = try c.decode(Date.self, forKey: .savedAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? savedAt
        deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
        readAt = try c.decodeIfPresent(Date.self, forKey: .readAt)
        progress = try c.decodeIfPresent(Double.self, forKey: .progress) ?? 0
        progressUpdatedAt = try c.decodeIfPresent(Date.self, forKey: .progressUpdatedAt)
        readStateUpdatedAt = try c.decodeIfPresent(Date.self, forKey: .readStateUpdatedAt)
    }
}

/// File helpers for the `pending_saves` handoff directory inside the shared
/// App Group container. Mirrors the `pending_shares` pattern used for
/// Mac-bound commands: the extension writes one JSON file per save, the main
/// app drains (reads + deletes) them on launch and foreground.
public enum SavedOnIPhoneFiles {
    public static let pendingDirName = "pending_saves"

    public static func pendingDirectory(in containerURL: URL) -> URL {
        containerURL.appendingPathComponent(pendingDirName, isDirectory: true)
    }

    public static func write(_ link: SavedOnIPhoneLink, containerURL: URL) throws {
        let dir = pendingDirectory(in: containerURL)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("\(link.id).json")
        let data = try JSONEncoder().encode(link)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Reads every queued save and removes the files, so each link is
    /// ingested exactly once even if drain runs twice.
    public static func drain(containerURL: URL) -> [SavedOnIPhoneLink] {
        let dir = pendingDirectory(in: containerURL)
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        var links: [SavedOnIPhoneLink] = []
        for file in files where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file),
               let link = try? JSONDecoder().decode(SavedOnIPhoneLink.self, from: data) {
                links.append(link)
            }
            try? FileManager.default.removeItem(at: file)
        }
        return links.sorted { $0.savedAt > $1.savedAt }
    }
}
