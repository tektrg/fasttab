import CryptoKit
import Foundation
import IndieLinks

/// Disk cache of site card metadata (one small JSON file per URL, in Caches), so relaunches
/// don't re-hit GitHub (60 calls/hour per IP) and Reddit, which rate-limit per IP.
/// Only metadata is stored; images are re-downloaded. Entries older than `timeToLive` are ignored;
/// a partial card (a source failed) is fetched once more after `LinkCardRetryPolicy.retryDelay`.
struct LinkCardMetadataCache: Sendable {
    static let defaultTimeToLive: TimeInterval = 7 * 24 * 60 * 60

    static let shared = LinkCardMetadataCache(
        directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LinkCardMetadata", isDirectory: true)
    )

    let directory: URL
    let timeToLive: TimeInterval
    let now: @Sendable () -> Date

    init(directory: URL, timeToLive: TimeInterval = Self.defaultTimeToLive, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.timeToLive = timeToLive
        self.now = now
    }

    private struct Entry: Codable {
        let savedAt: Date
        let metadata: LinkCardMetadata
        /// Set when the stored card was partial (a source failed): after this date it is
        /// fetched once more (`LinkCardRetryPolicy`). Nil for complete cards and for the retry's result.
        let retryAt: Date?
    }

    struct Hit {
        let metadata: LinkCardMetadata
        /// A partial card whose one retry is due: fetch again, and pass `wasRetry: true` to `store`.
        let isRetryDue: Bool
    }

    /// The stored card, or nil when none is stored or it is older than `timeToLive`.
    func lookup(_ url: URL) -> Hit? {
        guard let body = try? Data(contentsOf: fileURL(for: url)),
              let entry = try? JSONDecoder().decode(Entry.self, from: body),
              now().timeIntervalSince(entry.savedAt) < timeToLive
        else { return nil }
        let isRetryDue = entry.retryAt.map { now() >= $0 } ?? false
        return Hit(metadata: entry.metadata, isRetryDue: isRetryDue)
    }

    /// Stores a freshly fetched card. A partial one is scheduled for one retry unless this
    /// fetch was that retry. Images are not part of the rule: they are re-downloaded every
    /// launch anyway, so a failed picture download heals without refetching metadata.
    func store(_ metadata: LinkCardMetadata, for url: URL, wasRetry: Bool = false) {
        let savedAt = now()
        let retryAt = LinkCardRetryPolicy.retryDate(fetchedAt: savedAt, needsRetry: metadata.isPartial, wasRetry: wasRetry)
        guard let body = try? JSONEncoder().encode(Entry(savedAt: savedAt, metadata: metadata, retryAt: retryAt))
        else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? body.write(to: fileURL(for: url), options: .atomic)
    }

    private func fileURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(name).json")
    }
}
