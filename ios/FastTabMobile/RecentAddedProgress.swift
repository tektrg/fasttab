import Foundation
import FastTabSync

/// Read progress and tab membership for "Recent Added" rows, so the shelf and the "View all"
/// screen apply one rule (`LinkShelves`). A phone-saved link keeps its own progress in the
/// FastTab List (it also arrives from other devices); everything else uses the reader's
/// per-URL progress. The larger of the two wins.
@MainActor
struct RecentAddedProgress {
    let reading: ReaderReadingProgress
    let saved: SavedOnIPhoneStore

    init(reading: ReaderReadingProgress, saved: SavedOnIPhoneStore) {
        self.reading = reading
        self.saved = saved
    }

    init() {
        self.init(reading: .shared, saved: .shared)
    }

    func progress(_ item: RecentAddedItem) -> Double {
        var value = reading.progress(for: item.url)
        if let link = savedLink(item) { value = max(value, link.progress) }
        return value
    }

    /// When the link was last read: the later of the list's and the reader's timestamps.
    func lastRead(_ item: RecentAddedItem) -> Date? {
        [savedLink(item)?.progressUpdatedAt, reading.lastUpdated(for: item.url)].compactMap { $0 }.max()
    }

    /// The shelf: everything not finished.
    func shelf(_ items: [RecentAddedItem]) -> [RecentAddedItem] {
        LinkShelves.unfinished(items, progress: progress)
    }

    /// The "View all" tabs (FastTab List, Bookmarks, Read).
    func split(_ items: [RecentAddedItem]) -> LinkShelves.Split<RecentAddedItem> {
        LinkShelves.split(
            items,
            origin: { $0.source.isBookmark ? .bookmark : .fastTabList },
            progress: progress,
            finishedAt: lastRead
        )
    }

    private func savedLink(_ item: RecentAddedItem) -> SavedOnIPhoneLink? {
        guard case .savedOnIPhone(let linkID) = item.source else { return nil }
        return saved.items.first { $0.id == linkID }
    }
}
