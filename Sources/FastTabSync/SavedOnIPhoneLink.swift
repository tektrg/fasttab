import Foundation

/// A link the user chose to keep on this iPhone only (share sheet →
/// "Save to iPhone"). Local-only by design: it never becomes a `SyncCommand`
/// and is never uploaded to CloudKit. Lives in the shared App Group so the
/// share extension can write it and the main app can drain it.
public struct SavedOnIPhoneLink: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let url: String
    public let title: String?
    public let savedAt: Date

    public init(
        id: String = UUID().uuidString,
        url: String,
        title: String? = nil,
        savedAt: Date = Date()
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.savedAt = savedAt
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
