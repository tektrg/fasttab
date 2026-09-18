import Foundation

/// Persists `ReaderHighlight` items per article URL.
/// Backed by `UserDefaults`, keyed by canonical URL string.
@MainActor
public final class ReaderHighlightStore: ObservableObject {
    public static let shared = ReaderHighlightStore()

    private static let defaultsKey = "FastTabMobile.readerHighlightsV1"

    /// All highlights keyed by `urlKey`.
    @Published private var store: [String: [ReaderHighlight]] = [:]

    private init() {
        loadFromDisk()
    }

    // MARK: - Public API

    public func highlights(for url: URL) -> [ReaderHighlight] {
        store[canonical(url)] ?? []
    }

    public func add(_ highlight: ReaderHighlight) {
        var list = store[highlight.urlKey] ?? []
        list.append(highlight)
        store[highlight.urlKey] = list
        saveToDisk()
    }

    public func remove(id: String, url: URL) {
        let key = canonical(url)
        store[key]?.removeAll { $0.id == id }
        saveToDisk()
    }

    public func removeAll(for url: URL) {
        store.removeValue(forKey: canonical(url))
        saveToDisk()
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([String: [ReaderHighlight]].self, from: data) else {
            return
        }
        store = decoded
    }

    private func saveToDisk() {
        guard let encoded = try? JSONEncoder().encode(store) else { return }
        UserDefaults.standard.set(encoded, forKey: Self.defaultsKey)
    }

    private func canonical(_ url: URL) -> String {
        url.readerCanonicalKey
    }
}
