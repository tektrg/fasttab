import CryptoKit
import Foundation
import IndieLinks

/// Disk cache of site card metadata (one small JSON file per URL, in Caches), so relaunches
/// don't re-hit GitHub (60 calls/hour per IP) and Reddit, which rate-limit per IP.
/// Only metadata is stored; images are re-downloaded. Entries older than `timeToLive` are ignored.
struct LinkCardMetadataCache: Sendable {
    static let defaultTimeToLive: TimeInterval = 7 * 24 * 60 * 60

    static let shared = LinkCardMetadataCache(
        directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LinkCardMetadata", isDirectory: true)
    )

    let directory: URL
    let timeToLive: TimeInterval
    let now: @Sendable () -> Date

    init(directory: URL, timeToLive: TimeInterval = Self.defaultTimeToLive, now: @escaping @Sendable () -> Date = Date.init) {
        self.directory = directory
        self.timeToLive = timeToLive
        self.now = now
    }

    private struct Entry: Codable {
        let savedAt: Date
        let metadata: LinkCardMetadata
    }

    func metadata(for url: URL) -> LinkCardMetadata? {
        guard let body = try? Data(contentsOf: fileURL(for: url)),
              let entry = try? JSONDecoder().decode(Entry.self, from: body),
              now().timeIntervalSince(entry.savedAt) < timeToLive
        else { return nil }
        return entry.metadata
    }

    func store(_ metadata: LinkCardMetadata, for url: URL) {
        guard let body = try? JSONEncoder().encode(Entry(savedAt: now(), metadata: metadata)) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? body.write(to: fileURL(for: url), options: .atomic)
    }

    private func fileURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(name).json")
    }
}
