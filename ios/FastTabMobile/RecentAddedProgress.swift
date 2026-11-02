import Foundation
import FastTabSync

/// Read progress and tab membership for "Recent Added" rows, so the shelf and the "View all"
/// screen apply one rule (`LinkShelves`). A phone-saved link keeps its own progress in the
/// FastTab List (it also arrives from other devices); everything else uses the reader's
/// per-URL progress. The larger of the two wins. A link marked **Read Again** (a live list
/// item with the flag, whatever row it came in as) belongs to the Read Again tab only.
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

    /// When the link was marked Read Again; nil = not in Read Again.
    func readAgainAt(_ item: RecentAddedItem) -> Date? {
        saved.liveItem(for: item.url)?.readAgainAt
    }

    /// The shelf: everything not finished and not in Read Again.
    func shelf(_ items: [RecentAddedItem]) -> [RecentAddedItem] {
        LinkShelves.unfinished(items, progress: progress, isReadAgain: { readAgainAt($0) != nil })
    }

    /// The "View all" tabs (FastTab List, Bookmarks, Read Again, Read).
    func split(_ items: [RecentAddedItem]) -> LinkShelves.Split<RecentAddedItem> {
        LinkShelves.split(
            items,
            origin: { $0.source.isBookmark ? .bookmark : .fastTabList },
            progress: progress,
            finishedAt: lastRead,
            readAgainAt: readAgainAt
        )
    }

    /// The list item behind a row, matched by URL: a share-sheet or bookmark row whose link
    /// is also in the list (e.g. marked Read Again) uses the list's progress too.
    private func savedLink(_ item: RecentAddedItem) -> SavedOnIPhoneLink? {
        saved.liveItem(for: item.url)
    }
}
