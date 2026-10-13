import FastTabSync
import Foundation
import IndieTags

extension Notification.Name {
    /// Highlights or comments changed on this device; reader sync sends what is new.
    static let readerDataDidChangeLocally = Notification.Name("FastTabMobile.readerDataDidChangeLocally")
}

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
    /// False when the highlight is gone (deleted meanwhile).
    @discardableResult
    public func setCommentThreadId(_ threadId: String, for highlightID: String, urlKey: String) -> Bool {
        guard let index = store[urlKey]?.firstIndex(where: { $0.id == highlightID }),
              let highlight = store[urlKey]?[index] else { return false }
        store[urlKey]?[index] = highlight.replacingCommentThreadId(threadId)
        saveToDisk()
        return true
    }

    public func removeAll(for url: URL) {
        deleteCommentThreads(of: store[canonical(url)] ?? [])
        store.removeValue(forKey: canonical(url))
        saveToDisk()
    }

    /// A highlight's comments go with it (owner decision 2026-10-13).
    private func deleteCommentThreads(of removed: [ReaderHighlight]) {
        // All of them: a thread an agent opened carries no link but is still found.
        guard !removed.isEmpty else { return }
        Task { await ReaderCommentThreads.shared.deleteThreads(of: removed) }
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([String: [ReaderHighlight]].self, from: data) else {
            return
        }
        store = decoded
    }

    /// `announce` false for changes that came from sync, so they are not sent straight back.
    private func saveToDisk(announce: Bool = true) {
        guard let encoded = try? JSONEncoder().encode(store) else { return }
        UserDefaults.standard.set(encoded, forKey: Self.defaultsKey)
        if announce { NotificationCenter.default.post(name: .readerDataDidChangeLocally, object: nil) }
    }

    private func canonical(_ url: URL) -> String {
        url.readerCanonicalKey
    }
}

// MARK: - Reader sync (ReaderSyncBridge, ReaderZone)

extension ReaderHighlightStore: ReaderHighlightSyncStore {
    public func syncedHighlights() -> [SyncedReaderHighlight] {
        store.values.flatMap { $0 }.compactMap { highlight in
            (try? ReaderSyncBridge.encoder.encode(highlight)).map {
                SyncedReaderHighlight(id: highlight.id, urlKey: highlight.urlKey, payload: $0)
            }
        }
    }

    public func applyRemote(_ synced: SyncedReaderHighlight) -> Bool {
        guard let highlight = try? JSONDecoder().decode(ReaderHighlight.self, from: synced.payload) else { return false }
        // Its article key may have changed: never keep a second copy under the old one.
        for key in store.keys where key != highlight.urlKey {
            store[key]?.removeAll { $0.id == highlight.id }
        }
        var list = store[highlight.urlKey] ?? []
        if let index = list.firstIndex(where: { $0.id == highlight.id }) {
            list[index] = highlight
        } else {
            list.append(highlight)
        }
        store[highlight.urlKey] = list
        saveToDisk(announce: false)
        return true
    }

    /// No comment cascade: the deleting device's own delete events arrive with the sync.
    public func removeRemote(id: String) {
        for key in store.keys where store[key]?.contains(where: { $0.id == id }) == true {
            store[key]?.removeAll { $0.id == id }
        }
        saveToDisk(announce: false)
    }
}
