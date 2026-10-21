import Foundation
import CryptoKit

/// The FastTab List's rules as a plain value: dedupe, Trash, purge, read state.
/// No I/O and no clock of its own (every mutation takes `now`), so it is tested
/// directly; the phone's `SavedOnIPhoneStore` owns persistence and publishing.
/// Shared (FastTabSync) so the Mac derives the same ids and applies the same rules.
public struct FastTabListLibrary: Equatable, Sendable {
    /// Trashed items older than this become purged markers (deleted for good, never revived).
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
        itemsByID.values.filter { $0.isTrashed && !$0.isPurged }.sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }

    /// A visible (live or trashed) item; purged markers count as absent.
    public func item(id: String) -> SavedOnIPhoneLink? {
        itemsByID[id].flatMap { $0.isPurged ? nil : $0 }
    }

    public func item(forURL urlString: String) -> SavedOnIPhoneLink? {
        item(id: Self.itemID(for: urlString))
    }

    // MARK: - Mutations

    /// Saving a link already in the list moves it to the top (new `savedAt`), and a
    /// trashed one comes back out of Trash. Read state and progress are kept.
    /// Saving a purged link starts it fresh, with a `savedAt` after the purge so the
    /// restore wins the merge on every device.
    public mutating func save(_ link: SavedOnIPhoneLink, now: Date) {
        let id = Self.itemID(for: link.url)
        let freshSavedAt = itemsByID[id]?.purgedAt.map { max(link.savedAt, $0.addingTimeInterval(0.001)) } ?? link.savedAt
        var saved = item(id: id) ?? SavedOnIPhoneLink(id: id, url: link.url, savedAt: freshSavedAt)
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

    public mutating func deleteNow(id: String, now: Date) {
        guard item(id: id) != nil else { return }
        itemsByID[id] = .purgedMarker(id: id, purgedAt: now)
    }

    public mutating func emptyTrash(now: Date) {
        trashedItems.forEach { itemsByID[$0.id] = .purgedMarker(id: $0.id, purgedAt: now) }
    }

    /// Turns Trash older than `trashRetention` into purged markers. Returns whether any did.
    @discardableResult
    public mutating func purgeExpiredTrash(now: Date) -> Bool {
        let cutoff = now.addingTimeInterval(-Self.trashRetention)
        let expired = trashedItems.filter { ($0.deletedAt ?? .distantFuture) <= cutoff }
        expired.forEach { itemsByID[$0.id] = .purgedMarker(id: $0.id, purgedAt: now) }
        return !expired.isEmpty
    }

    /// Records reader progress for a list item; reaching `readThreshold` marks it read
    /// (never un-marks). Returns false when the URL isn't in the list or nothing changed.
    @discardableResult
    public mutating func recordProgress(url urlString: String, progress: Double, now: Date) -> Bool {
        let id = Self.itemID(for: urlString)
        guard var item = item(id: id) else { return false }
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
        guard let item = item(id: id), item.isRead != isRead else { return }
        update(id: id, now: now) {
            $0.readAt = isRead ? now : nil
            $0.readStateUpdatedAt = now
        }
    }

    private mutating func update(id: String, now: Date, _ change: (inout SavedOnIPhoneLink) -> Void) {
        guard var item = item(id: id) else { return }
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

    /// The record was deleted in CloudKit (a build from before purged markers). Kept as a
    /// marker so a long-offline device can't bring it back; the marker syncs out.
    @discardableResult
    public mutating func removeRemote(id: String, now: Date) -> Bool {
        guard itemsByID[id]?.isPurged != true else { return false }
        itemsByID[id] = .purgedMarker(id: id, purgedAt: now)
        return true
    }

    /// Loading/migrating: re-keys by canonical URL and keeps the most recent copy.
    private mutating func upsertKeepingNewest(_ incoming: SavedOnIPhoneLink) {
        var item = incoming
        // Markers have no URL; their id is the identity.
        if !incoming.isPurged { item.id = Self.itemID(for: incoming.url) }
        if let existing = itemsByID[item.id], existing.updatedAt >= item.updatedAt { return }
        itemsByID[item.id] = item
    }
}
