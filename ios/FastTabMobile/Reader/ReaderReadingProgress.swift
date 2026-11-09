import FastTabSync
import Foundation

extension Notification.Name {
    /// Reading progress changed on this phone (`SyncConsumer` sends it as reading activity).
    static let readingActivityDidChangeLocally = Notification.Name("FastTabMobile.readingActivityDidChangeLocally")
}

/// Persists scroll progress (0.0 – 1.0) per article URL.
/// Backed by `UserDefaults`, capped at 200 entries (LRU eviction).
/// Also the phone's reading-activity sync store: every entry goes to the Mac as a
/// `ReadingActivity` (the reading connector's "what did I read"), list item or not.
@MainActor
public final class ReaderReadingProgress: ObservableObject, ReadingActivitySyncStore {
    public static let shared = ReaderReadingProgress()

    private static let defaultsKey = "FastTabMobile.readerReadingProgressV1"
    private static let maxEntries = 200

    /// Maps a URL's canonical string to its progress value.
    @Published private var store: [String: ProgressEntry] = [:]

    private struct ProgressEntry: Codable {
        var progress: Double      // 0.0 – 1.0
        var updatedAt: Date
        /// Page title when known (entries from before activity sync have none).
        var title: String?
    }

    private init() {
        loadFromDisk()
    }

    // MARK: - Public API

    public func progress(for url: URL) -> Double {
        store[canonical(url)]?.progress ?? 0.0
    }

    /// When the article's progress last changed (for a finished article: when it was read).
    public func lastUpdated(for url: URL) -> Date? {
        store[canonical(url)]?.updatedAt
    }

    public func set(progress: Double, for url: URL, title: String? = nil) {
        let key = canonical(url)
        let clamped = max(0, min(1, progress))
        let knownTitle = title.flatMap { $0.isEmpty ? nil : $0 } ?? store[key]?.title
        // Same value re-saved (reopen, flush on dismiss): nothing changed, nothing to sync.
        if let existing = store[key], abs(existing.progress - clamped) < 0.001, existing.title == knownTitle { return }
        store[key] = ProgressEntry(progress: clamped, updatedAt: Date(), title: knownTitle)
        evictIfNeeded()
        saveToDisk()
        NotificationCenter.default.post(name: .readingActivityDidChangeLocally, object: nil)
    }

    // MARK: - Reading activity sync

    /// Every entry with progress; the canonical key is itself the URL.
    public func readingActivitiesForSync() -> [ReadingActivity] {
        Self.activities(from: store.mapValues { ($0.progress, $0.updatedAt, $0.title) })
    }

    /// The phone keeps its own position: another device's activity only fills a title or
    /// moves an entry forward when it is newer (another phone/iPad read further later).
    public func applyRemoteReadingActivities(_ activities: [ReadingActivity]) {
        var changed = false
        for remote in activities {
            guard let url = URL(string: remote.url) else { continue }
            let key = canonical(url)
            let local = store[key]
            guard local.map({ remote.lastReadAt > $0.updatedAt }) ?? false else { continue }
            store[key] = ProgressEntry(progress: remote.progress, updatedAt: remote.lastReadAt,
                                       title: remote.title ?? local?.title)
            changed = true
        }
        if changed { saveToDisk() }
    }

    /// Pure: progress entries (canonical key → progress, updatedAt, title) as activities.
    /// Unstarted pages (progress ~0) are left out.
    nonisolated static func activities(from entries: [String: (Double, Date, String?)]) -> [ReadingActivity] {
        entries.compactMap { key, value in
            guard value.0 > 0.005 else { return nil }
            return ReadingActivity(url: key, title: value.2, progress: value.0, lastReadAt: value.1)
        }.sorted { $0.lastReadAt > $1.lastReadAt }
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([String: ProgressEntry].self, from: data) else {
            return
        }
        store = decoded
    }

    private func saveToDisk() {
        guard let encoded = try? JSONEncoder().encode(store) else { return }
        UserDefaults.standard.set(encoded, forKey: Self.defaultsKey)
    }

    private func evictIfNeeded() {
        guard store.count > Self.maxEntries else { return }
        // Remove oldest entries to trim to limit
        let sorted = store.sorted { $0.value.updatedAt < $1.value.updatedAt }
        let toRemove = sorted.prefix(store.count - Self.maxEntries)
        toRemove.forEach { store.removeValue(forKey: $0.key) }
    }

    private func canonical(_ url: URL) -> String {
        url.readerCanonicalKey
    }
}
