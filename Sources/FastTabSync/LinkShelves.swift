import Foundation

/// Pure rules for the Read tab's "Recent Added" shelf and its "View all" screen.
///
/// A link read to the end (99-100%) leaves every working list and shows only under
/// the screen's **Read** tab. A link marked **Read Again** shows only under Read Again,
/// whatever its progress, until the user unmarks it. Kept here, free of UIKit and stores, so the rule and
/// the split can be unit-tested without a simulator.
public enum LinkShelves {
    /// Reading progress at or above this counts as "finished" (the PO's "99-100%").
    /// Scroll progress rarely lands on exactly 1.0, so 0.99 is the finish line.
    public static let finishedThreshold: Double = 0.99

    public static func isFinished(progress: Double) -> Bool {
        progress >= finishedThreshold
    }

    /// Which "View all" tab a link belongs to before the finished rule is applied.
    public enum Origin: Sendable {
        /// Saved on the phone (FastTab List) or sent to the Mac from the share sheet.
        case fastTabList
        /// A synced Mac bookmark.
        case bookmark
    }

    public struct Split<Item> {
        /// Unfinished phone-saved and shared links, input order kept.
        public var fastTabList: [Item]
        /// Unfinished Mac bookmarks, input order kept.
        public var bookmarks: [Item]
        /// Links marked Read Again (any origin, any progress), most recently marked first.
        public var readAgain: [Item]
        /// Finished links from either origin, most recently read first.
        public var read: [Item]
    }

    /// Splits `items` (already newest-first) into the four tabs.
    /// - `progress`: the best-known read progress for the item (0 when never opened).
    /// - `finishedAt`: when the item was last read, used only to order the Read tab;
    ///   items without a date sort after those with one, keeping input order.
    /// - `readAgainAt`: when the item was marked Read Again; nil = not marked.
    public static func split<Item>(
        _ items: [Item],
        origin: (Item) -> Origin,
        progress: (Item) -> Double,
        finishedAt: (Item) -> Date? = { _ in nil },
        readAgainAt: (Item) -> Date? = { _ in nil }
    ) -> Split<Item> {
        var list: [Item] = []
        var bookmarks: [Item] = []
        var readAgain: [(item: Item, at: Date?, index: Int)] = []
        var finished: [(item: Item, at: Date?, index: Int)] = []
        for (index, item) in items.enumerated() {
            if let markedAt = readAgainAt(item) {
                readAgain.append((item, markedAt, index))
                continue
            }
            if isFinished(progress: progress(item)) {
                finished.append((item, finishedAt(item), index))
                continue
            }
            switch origin(item) {
            case .fastTabList: list.append(item)
            case .bookmark: bookmarks.append(item)
            }
        }
        return Split(
            fastTabList: list, bookmarks: bookmarks,
            readAgain: newestFirst(readAgain), read: newestFirst(finished)
        )
    }

    /// Dated entries newest first, undated after them; ties keep input order.
    private static func newestFirst<Item>(_ entries: [(item: Item, at: Date?, index: Int)]) -> [Item] {
        entries.sorted { lhs, rhs in
            switch (lhs.at, rhs.at) {
            case let (l?, r?) where l != r: return l > r
            case (.some, nil): return true
            case (nil, .some): return false
            default: return lhs.index < rhs.index
            }
        }.map(\.item)
    }

    /// The shelf itself: everything that is not finished and not in Read Again, order kept.
    public static func unfinished<Item>(
        _ items: [Item], progress: (Item) -> Double, isReadAgain: (Item) -> Bool = { _ in false }
    ) -> [Item] {
        items.filter { !isReadAgain($0) && !isFinished(progress: progress($0)) }
    }
}
