import Foundation
import FastTabSync

/// Phone-local "read to the end" count per article URL, for links with no FastTab List item
/// (plain bookmarks, tabs, cards). List items also carry a synced `readCount`; rows show the
/// larger of the two. Same storage style as `ReaderReadingProgress`: `UserDefaults`, capped
/// at 200 entries, least recently counted evicted first.
@MainActor
public final class ReaderReadCounts: ObservableObject {
    public static let shared = ReaderReadCounts()

    static let defaultsKey = "FastTabMobile.readerReadCountsV1"
    static let maxEntries = 200

    @Published private var store: [String: Entry] = [:]
    private let defaults: UserDefaults

    private struct Entry: Codable {
        var count: Int
        var updatedAt: Date
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            store = decoded
        }
    }

    public func count(for url: URL) -> Int {
        store[url.readerCanonicalKey]?.count ?? 0
    }

    public func increment(_ url: URL, now: Date = Date()) {
        let key = url.readerCanonicalKey
        store[key] = Entry(count: (store[key]?.count ?? 0) + 1, updatedAt: now)
        if store.count > Self.maxEntries {
            let oldest = store.sorted { $0.value.updatedAt < $1.value.updatedAt }.prefix(store.count - Self.maxEntries)
            oldest.forEach { store.removeValue(forKey: $0.key) }
        }
        if let data = try? JSONEncoder().encode(store) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

/// What a row or card shows for one link: the best-known read count (phone-local vs the list
/// item's synced count) and whether it's in Read Again.
@MainActor
struct LinkReadState {
    let saved: SavedOnIPhoneStore
    let counts: ReaderReadCounts

    init(saved: SavedOnIPhoneStore = .shared, counts: ReaderReadCounts = .shared) {
        self.saved = saved
        self.counts = counts
    }

    func readCount(_ url: URL) -> Int {
        max(counts.count(for: url), saved.liveItem(for: url)?.readCount ?? 0)
    }

    func isReadAgain(_ url: URL) -> Bool {
        saved.isReadAgain(url)
    }

    /// Mark / unmark from any surface. Returns the toast text.
    @discardableResult
    func toggleReadAgain(url: URL, title: String?) -> String {
        if saved.isReadAgain(url) {
            saved.removeFromReadAgain(url: url)
            return "Removed from Read Again"
        }
        let added = saved.markReadAgain(url: url.absoluteString, title: title, localReadCount: counts.count(for: url))
        return added ? "Added to Read Again" : "Can't add this link"
    }
}

/// One label pair for every surface (rows, cards, Shuffle, End of Article).
enum ReadAgainLabel {
    static let mark = "Read Again"
    static let unmark = "Remove from Read Again"
    static let markIcon = "arrow.counterclockwise.circle"
    static let unmarkIcon = "minus.circle"

    static func title(isReadAgain: Bool) -> String { isReadAgain ? unmark : mark }
    static func icon(isReadAgain: Bool) -> String { isReadAgain ? unmarkIcon : markIcon }
}
