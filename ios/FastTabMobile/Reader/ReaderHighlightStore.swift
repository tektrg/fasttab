import Foundation
import IndieTags

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

    /// Every highlight across every article, newest first.
    public func allHighlightsNewestFirst() -> [ReaderHighlight] {
        store.values.flatMap { $0 }.sorted { $0.createdAt > $1.createdAt }
    }

    public func highlight(id: String, urlKey: String) -> ReaderHighlight? {
        store[urlKey]?.first { $0.id == id }
    }

    public func add(_ highlight: ReaderHighlight) {
        var list = store[highlight.urlKey] ?? []
        list.append(highlight)
        store[highlight.urlKey] = list
        saveToDisk()
    }

    public func remove(id: String, url: URL) {
        let key = canonical(url)
        deleteCommentThreads(of: store[key]?.filter { $0.id == id } ?? [])
        store[key]?.removeAll { $0.id == id }
        saveToDisk()
    }

    /// Removes a highlight without needing to reconstruct its article `URL` — `urlKey` is
    /// already canonical, so it doubles as the store's dictionary key directly.
    public func remove(_ highlight: ReaderHighlight) {
        deleteCommentThreads(of: store[highlight.urlKey]?.filter { $0.id == highlight.id } ?? [])
        store[highlight.urlKey]?.removeAll { $0.id == highlight.id }
        saveToDisk()
    }

    /// Replaces a highlight's user tags. Paths are tidied and de-duplicated (case and accents
    /// ignored); anything that is not a valid `TagPath` is dropped.
    public func setTags(_ tags: [String], for highlight: ReaderHighlight) {
        guard let index = store[highlight.urlKey]?.firstIndex(where: { $0.id == highlight.id }) else { return }
        var seenPaths = Set<String>()
        let cleanedTags = tags.compactMap(TagPath.init)
            .filter { seenPaths.insert($0.normalizedPath).inserted }
            .map(\.displayPath)
        store[highlight.urlKey]?[index] = highlight.replacingTags(cleanedTags)
        saveToDisk()
    }

    /// Links a highlight to its comment thread (set when its first comment is written).
    public func setCommentThreadId(_ threadId: String, for highlightID: String, urlKey: String) {
        guard let index = store[urlKey]?.firstIndex(where: { $0.id == highlightID }),
              let highlight = store[urlKey]?[index] else { return }
        store[urlKey]?[index] = highlight.replacingCommentThreadId(threadId)
        saveToDisk()
    }

    public func removeAll(for url: URL) {
        deleteCommentThreads(of: store[canonical(url)] ?? [])
        store.removeValue(forKey: canonical(url))
        saveToDisk()
    }

    /// A highlight's comments go with it (owner decision 2026-10-13).
    private func deleteCommentThreads(of removed: [ReaderHighlight]) {
        let commented = removed.filter { $0.commentThreadId != nil }
        guard !commented.isEmpty else { return }
        Task { await ReaderCommentThreads.shared.deleteThreads(of: commented) }
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
