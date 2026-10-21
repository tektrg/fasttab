import Foundation
import CryptoKit
import FastTabSync

/// The FastTab List's rules as a plain value: dedupe, Trash, purge, read state.
/// No I/O and no clock of its own (every mutation takes `now`), so it is tested
/// directly; `SavedOnIPhoneStore` owns persistence and publishing.
struct FastTabListLibrary: Equatable {
    /// Trashed items older than this are deleted for good.
    static let trashRetention: TimeInterval = 30 * 86_400
    /// Scroll fraction that counts as "read".
    static let readThreshold = 0.9

    private(set) var itemsByID: [String: SavedOnIPhoneLink] = [:]

    init(items: [SavedOnIPhoneLink] = []) {
        for item in items { upsertKeepingNewest(item) }
    }

    /// Stable id for a URL: same link (after canonicalisation) → same id on every
    /// device, which is what lets phase 2 sync merge instead of duplicate.
    static func itemID(for urlString: String) -> String {
        let key = URL(string: urlString)?.readerCanonicalKey ?? urlString.lowercased()
        return SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    var liveItems: [SavedOnIPhoneLink] {
        itemsByID.values.filter { !$0.isTrashed }.sorted { $0.savedAt > $1.savedAt }
    }

    var trashedItems: [SavedOnIPhoneLink] {
        itemsByID.values.filter(\.isTrashed).sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }

    func item(forURL urlString: String) -> SavedOnIPhoneLink? {
        itemsByID[Self.itemID(for: urlString)]
    }

    // MARK: - Mutations

    /// Saving a link already in the list moves it to the top (new `savedAt`), and a
    /// trashed one comes back out of Trash. Read state and progress are kept.
    mutating func save(_ link: SavedOnIPhoneLink, now: Date) {
        let id = Self.itemID(for: link.url)
        var saved = itemsByID[id] ?? SavedOnIPhoneLink(id: id, url: link.url, savedAt: link.savedAt)
        saved.url = link.url
        if let title = link.title, !title.isEmpty { saved.title = title }
        saved.savedAt = max(saved.savedAt, link.savedAt)
        saved.deletedAt = nil
        saved.updatedAt = now
        itemsByID[id] = saved
    }

    mutating func moveToTrash(id: String, now: Date) {
        update(id: id, now: now) { $0.deletedAt = now }
    }

    mutating func restore(id: String, now: Date) {
        update(id: id, now: now) { $0.deletedAt = nil }
    }

    mutating func deleteNow(id: String) {
        itemsByID[id] = nil
    }

    mutating func emptyTrash() {
        itemsByID = itemsByID.filter { !$0.value.isTrashed }
    }

    /// Returns whether anything was purged.
    @discardableResult
    mutating func purgeExpiredTrash(now: Date) -> Bool {
        let cutoff = now.addingTimeInterval(-Self.trashRetention)
        let before = itemsByID.count
        itemsByID = itemsByID.filter { ($0.value.deletedAt ?? .distantFuture) > cutoff }
        return itemsByID.count != before
    }

    /// Records reader progress for a list item; reaching `readThreshold` marks it read
    /// (never un-marks). Returns false when the URL isn't in the list or nothing changed.
    @discardableResult
    mutating func recordProgress(url urlString: String, progress: Double, now: Date) -> Bool {
        let id = Self.itemID(for: urlString)
        guard var item = itemsByID[id] else { return false }
        let clamped = max(0, min(1, progress))
        let becomesRead = clamped >= Self.readThreshold && item.readAt == nil
        guard abs(item.progress - clamped) > 0.001 || becomesRead else { return false }
        item.progress = clamped
        item.progressUpdatedAt = now
        if becomesRead { item.readAt = now }
        item.updatedAt = now
        itemsByID[id] = item
        return true
    }

    mutating func setRead(id: String, _ isRead: Bool, now: Date) {
        update(id: id, now: now) { $0.readAt = isRead ? ($0.readAt ?? now) : nil }
    }

    private mutating func update(id: String, now: Date, _ change: (inout SavedOnIPhoneLink) -> Void) {
        guard var item = itemsByID[id] else { return }
        change(&item)
        item.updatedAt = now
        itemsByID[id] = item
    }

    /// Loading/migrating: re-keys by canonical URL and keeps the most recent copy.
    private mutating func upsertKeepingNewest(_ incoming: SavedOnIPhoneLink) {
        var item = incoming
        item.id = Self.itemID(for: incoming.url)
        if let existing = itemsByID[item.id], existing.updatedAt >= item.updatedAt { return }
        itemsByID[item.id] = item
    }
}
