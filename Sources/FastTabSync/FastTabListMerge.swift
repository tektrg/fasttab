import Foundation

/// How two copies of one FastTab List item (same id) combine. Pure and symmetric:
/// `merge(a, b) == merge(b, a)`, so every device converges whatever order copies arrive.
///
/// - url / title / Trash state (`deletedAt`): the copy with the newer `updatedAt`.
/// - progress: the newer `progressUpdatedAt` (reading on one device isn't undone by a
///   title edit on another).
/// - read state (`readAt`): the newer `readStateUpdatedAt`, so "mark unread" sticks.
/// - `savedAt` / `updatedAt`: the later of the two.
public enum FastTabListMerge {
    public static func merge(_ a: SavedOnIPhoneLink, _ b: SavedOnIPhoneLink) -> SavedOnIPhoneLink {
        var merged = newerEdit(a, b)
        merged.savedAt = max(a.savedAt, b.savedAt)
        merged.updatedAt = max(a.updatedAt, b.updatedAt)

        let progressSource = newer(a, b, by: { ($0.progressUpdatedAt ?? .distantPast, $0.progress) })
        merged.progress = progressSource.progress
        merged.progressUpdatedAt = progressSource.progressUpdatedAt

        let readSource = newer(a, b, by: {
            ($0.readStateUpdatedAt ?? $0.readAt ?? .distantPast, ($0.readAt ?? .distantPast).timeIntervalSinceReferenceDate)
        })
        merged.readAt = readSource.readAt
        merged.readStateUpdatedAt = readSource.readStateUpdatedAt
        return merged
    }

    /// Ties (same `updatedAt`) break on content, never on argument order.
    private static func newerEdit(_ a: SavedOnIPhoneLink, _ b: SavedOnIPhoneLink) -> SavedOnIPhoneLink {
        if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt ? a : b }
        let keyA = ((a.deletedAt ?? .distantPast).timeIntervalSinceReferenceDate, a.title ?? "", a.url)
        let keyB = ((b.deletedAt ?? .distantPast).timeIntervalSinceReferenceDate, b.title ?? "", b.url)
        return keyA >= keyB ? a : b
    }

    private static func newer(
        _ a: SavedOnIPhoneLink, _ b: SavedOnIPhoneLink, by key: (SavedOnIPhoneLink) -> (Date, Double)
    ) -> SavedOnIPhoneLink {
        let keyA = key(a), keyB = key(b)
        return (keyA.0, keyA.1) >= (keyB.0, keyB.1) ? a : b
    }
}
