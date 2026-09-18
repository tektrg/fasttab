import Foundation

/// Persists scroll progress (0.0 – 1.0) per article URL.
/// Backed by `UserDefaults`, capped at 200 entries (LRU eviction).
@MainActor
public final class ReaderReadingProgress: ObservableObject {
    public static let shared = ReaderReadingProgress()

    private static let defaultsKey = "FastTabMobile.readerReadingProgressV1"
    private static let maxEntries = 200

    /// Maps a URL's canonical string to its progress value.
    @Published private var store: [String: ProgressEntry] = [:]

    private struct ProgressEntry: Codable {
        var progress: Double      // 0.0 – 1.0
        var updatedAt: Date
    }

    private init() {
        loadFromDisk()
    }

    // MARK: - Public API

    public func progress(for url: URL) -> Double {
        store[canonical(url)]?.progress ?? 0.0
    }

    public func set(progress: Double, for url: URL) {
        let key = canonical(url)
        store[key] = ProgressEntry(progress: max(0, min(1, progress)), updatedAt: Date())
        evictIfNeeded()
        saveToDisk()
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
