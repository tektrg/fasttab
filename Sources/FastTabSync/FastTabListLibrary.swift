import Foundation
import CryptoKit

/// The FastTab List's rules as a plain value: dedupe, Trash, purge, read state.
/// No I/O and no clock of its own (every mutation takes `now`), so it is tested
/// directly; the phone's `SavedOnIPhoneStore` owns persistence and publishing.
/// Shared (FastTabSync) so the Mac derives the same ids and applies the same rules.
public struct FastTabListLibrary: Equatable, Sendable {
    /// Trashed items older than this are deleted for good.
    public static let trashRetention: TimeInterval = 30 * 86_400
    /// Scroll fraction that counts as "read".
    public static let readThreshold = 0.9

    public private(set) var itemsByID: [String: SavedOnIPhoneLink] = [:]

    public init(items: [SavedOnIPhoneLink] = []) {
        for item in items { upsertKeepingNewest(item) }
    }

    /// Stable id for a URL: same link (after canonicalisation) → same id on every
    /// device, which is what lets phase 2 sync merge instead of duplicate.
    public static func itemID(for urlString: String) -> String {
        let key = URL(string: urlString)?.readerCanonicalKey ?? urlString.lowercased()
        return SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    public var liveItems: [SavedOnIPhoneLink] {
        itemsByID.values.filter { !$0.isTrashed }.sorted { $0.savedAt > $1.savedAt }
    }

    public var trashedItems: [SavedOnIPhoneLink] {
        itemsByID.values.filter(\.isTrashed).sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }

    public func item(forURL urlString: String) -> SavedOnIPhoneLink? {
        itemsByID[Self.itemID(for: urlString)]
    }

    // MARK: - Mutations

    /// Saving a link already in the list moves it to the top (new `savedAt`), and a
    /// trashed one comes back out of Trash. Read state and progress are kept.
    public mutating func save(_ link: SavedOnIPhoneLink, now: Date) {
        let id = Self.itemID(for: link.url)
        var saved = itemsByID[id] ?? SavedOnIPhoneLink(id: id, url: link.url, savedAt: link.savedAt)
        saved.url = link.url
        if let title = link.title, !title.isEmpty { saved.title = title }
        saved.savedAt = max(saved.savedAt, link.savedAt)
        saved.deletedAt = nil
        saved.updatedAt = now
        itemsByID[id] = saved
    }

    public mutating func moveToTrash(id: String, now: Date) {
        update(id: id, now: now) { $0.deletedAt = now }
    }

    public mutating func restore(id: String, now: Date) {
        update(id: id, now: now) { $0.deletedAt = nil }
    }

    public mutating func deleteNow(id: String) {
        itemsByID[id] = nil
    }

    public mutating func emptyTrash() {
        itemsByID = itemsByID.filter { !$0.value.isTrashed }
    }

    /// Returns whether anything was purged.
    @discardableResult
    public mutating func purgeExpiredTrash(now: Date) -> Bool {
        let cutoff = now.addingTimeInterval(-Self.trashRetention)
        let before = itemsByID.count
        itemsByID = itemsByID.filter { ($0.value.deletedAt ?? .distantFuture) > cutoff }
        return itemsByID.count != before
    }

    /// Records reader progress for a list item; reaching `readThreshold` marks it read
    /// (never un-marks). Returns false when the URL isn't in the list or nothing changed.
    @discardableResult
    public mutating func recordProgress(url urlString: String, progress: Double, now: Date) -> Bool {
        let id = Self.itemID(for: urlString)
        guard var item = itemsByID[id] else { return false }
        let clamped = max(0, min(1, progress))
        let becomesRead = clamped >= Self.readThreshold && item.readAt == nil
        guard abs(item.progress - clamped) > 0.001 || becomesRead else { return false }
        item.progress = clamped
        item.progressUpdatedAt = now
        if becomesRead {
            item.readAt = now
            item.readStateUpdatedAt = now
        }
        item.updatedAt = now
        itemsByID[id] = item
        return true
    }

    public mutating func setRead(id: String, _ isRead: Bool, now: Date) {
        guard let item = itemsByID[id], item.isRead != isRead else { return }
        update(id: id, now: now) {
            $0.readAt = isRead ? now : nil
            $0.readStateUpdatedAt = now
        }
    }

    private mutating func update(id: String, now: Date, _ change: (inout SavedOnIPhoneLink) -> Void) {
        guard var item = itemsByID[id] else { return }
        change(&item)
        item.updatedAt = now
        itemsByID[id] = item
    }

    // MARK: - Sync

    /// Another device's copy: merged field by field (`FastTabListMerge`). Returns what
    /// this library now holds for that id.
    @discardableResult
    public mutating func applyRemote(_ remote: SavedOnIPhoneLink) -> SavedOnIPhoneLink {
        let merged = itemsByID[remote.id].map { FastTabListMerge.merge($0, remote) } ?? remote
        itemsByID[remote.id] = merged
        return merged
    }

    /// The record was deleted in CloudKit (purged or Trash emptied on another device).
    @discardableResult
    public mutating func removeRemote(id: String) -> Bool {
        itemsByID.removeValue(forKey: id) != nil
    }

    /// Loading/migrating: re-keys by canonical URL and keeps the most recent copy.
    private mutating func upsertKeepingNewest(_ incoming: SavedOnIPhoneLink) {
        var item = incoming
        item.id = Self.itemID(for: incoming.url)
        if let existing = itemsByID[item.id], existing.updatedAt >= item.updatedAt { return }
        itemsByID[item.id] = item
    }
}
