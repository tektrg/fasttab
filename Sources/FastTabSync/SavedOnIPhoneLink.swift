import Foundation

/// One entry in the **FastTab List** — the user's read-later list (product name;
/// the Swift type keeps its older "Saved on iPhone" name). Distinct from browser
/// Bookmarks, which are browser-owned. Synced across devices through `ReaderZone`
/// (`FastTabListSyncBridge`; per-field merge in `FastTabListMerge`):
/// - `id` is derived from the canonical URL by the store, so the same link saved on
///   two devices becomes the same item.
/// - `deletedAt` is a tombstone: set = in Trash (purged after 30 days), nil = live.
/// - `purgedAt` marks a **purged marker**: what is left after Trash is emptied or expires.
///   Only `id` + `purgedAt` mean anything (title, URL, progress are stripped). It is
///   final: an older edit from a long-offline device never revives it; only an explicit
///   re-save (a `savedAt` newer than `purgedAt`) does. Never shown in any UI.
/// - `readAt` / `progress` carry read state; each change bumps `updatedAt`
///   (`progressUpdatedAt` for progress) so a later merge can pick the newest.
/// - `readAgainAt`: set = in **Read Again** (the user wants to reread it; stays until they
///   unmark it). `readAgainUpdatedAt` stamps each mark/unmark so "Remove" propagates.
/// - `readCount`: times read to the end (`ReadSession`); merges as the larger count.
/// - `unknownFields`: JSON keys from newer builds, kept verbatim so this build re-encoding
///   an item never drops a field it doesn't know (builds before Read Again did drop them).
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
    /// Set = purged marker (see type doc).
    public var purgedAt: Date?
    /// Set = marked "Read Again" (when it was marked).
    public var readAgainAt: Date?
    /// When `readAgainAt` last changed (set or cleared).
    public var readAgainUpdatedAt: Date?
    /// Times read to the end (0 = never counted).
    public var readCount: Int
    /// When `readCount` last went up.
    public var readCountUpdatedAt: Date?
    /// Fields this build doesn't know, passed through untouched (see type doc).
    public var unknownFields: [String: OpaqueJSON] = [:]

    public var isPurged: Bool { purgedAt != nil }
    public var isTrashed: Bool { deletedAt != nil }
    public var isRead: Bool { readAt != nil }
    public var isReadAgain: Bool { readAgainAt != nil }

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
        readStateUpdatedAt: Date? = nil,
        purgedAt: Date? = nil,
        readAgainAt: Date? = nil,
        readAgainUpdatedAt: Date? = nil,
        readCount: Int = 0,
        readCountUpdatedAt: Date? = nil
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
        self.purgedAt = purgedAt
        self.readAgainAt = readAgainAt
        self.readAgainUpdatedAt = readAgainUpdatedAt
        self.readCount = readCount
        self.readCountUpdatedAt = readCountUpdatedAt
    }

    /// The permanent "purged" marker for `id`. Canonical for a given `purgedAt`, so every
    /// device builds identical bytes. `deletedAt` is set too, so builds that predate
    /// markers treat it as Trash and keep it hidden.
    public static func purgedMarker(id: String, purgedAt: Date) -> SavedOnIPhoneLink {
        SavedOnIPhoneLink(id: id, url: "", savedAt: purgedAt, updatedAt: purgedAt,
                          deletedAt: purgedAt, purgedAt: purgedAt)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, url, title, savedAt, updatedAt, deletedAt, readAt, progress, progressUpdatedAt, readStateUpdatedAt, purgedAt
        case readAgainAt, readAgainUpdatedAt, readCount, readCountUpdatedAt
    }

    private static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))

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
        purgedAt = try c.decodeIfPresent(Date.self, forKey: .purgedAt)
        // Newer fields never fail the item (a bad value reads as unset): one undecodable
        // item would otherwise lose the whole list file.
        readAgainAt = try? c.decodeIfPresent(Date.self, forKey: .readAgainAt)
        readAgainUpdatedAt = try? c.decodeIfPresent(Date.self, forKey: .readAgainUpdatedAt)
        readCount = max(0, (try? c.decodeIfPresent(Int.self, forKey: .readCount)) ?? 0)
        readCountUpdatedAt = try? c.decodeIfPresent(Date.self, forKey: .readCountUpdatedAt)

        let all = try decoder.container(keyedBy: AnyCodingKey.self)
        for key in all.allKeys where !Self.knownKeys.contains(key.stringValue) {
            if let value = try? all.decode(OpaqueJSON.self, forKey: key) {
                unknownFields[key.stringValue] = value
            }
        }
    }

    /// One dynamic-key container for known and unknown fields alike; an unknown field never
    /// reuses a known key (filtered on both decode and encode).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        for (key, value) in unknownFields where !Self.knownKeys.contains(key) {
            try c.encode(value, forKey: AnyCodingKey(key))
        }
        func put<T: Encodable>(_ value: T?, _ key: CodingKeys) throws {
            if let value { try c.encode(value, forKey: AnyCodingKey(key.rawValue)) }
        }
        try put(id, .id)
        try put(url, .url)
        try put(title, .title)
        try put(savedAt, .savedAt)
        try put(updatedAt, .updatedAt)
        try put(deletedAt, .deletedAt)
        try put(readAt, .readAt)
        try put(progress, .progress)
        try put(progressUpdatedAt, .progressUpdatedAt)
        try put(readStateUpdatedAt, .readStateUpdatedAt)
        try put(purgedAt, .purgedAt)
        try put(readAgainAt, .readAgainAt)
        try put(readAgainUpdatedAt, .readAgainUpdatedAt)
        // 0 is the default: omitted, so items that were never re-read keep their old bytes.
        if readCount > 0 { try put(readCount, .readCount) }
        try put(readCountUpdatedAt, .readCountUpdatedAt)
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
