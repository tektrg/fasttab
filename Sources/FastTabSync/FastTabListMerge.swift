import Foundation

/// How two copies of one FastTab List item (same id) combine. Pure and symmetric:
/// `merge(a, b) == merge(b, a)`, so every device converges whatever order copies arrive.
///
/// - url / title / Trash state (`deletedAt`): the copy with the newer `updatedAt`.
/// - progress: the newer `progressUpdatedAt` (reading on one device isn't undone by a
///   title edit on another).
/// - read state (`readAt`): the newer `readStateUpdatedAt`, so "mark unread" sticks.
/// - Read Again (`readAgainAt`): the newer `readAgainUpdatedAt`, so "Remove from Read
///   Again" sticks the same way.
/// - `readCount`: the larger count. Two devices that each finish a reread while offline
///   both go 2 → 3, so the merge says 3, not 4: a known, accepted undercount by one.
/// - `unknownFields` (from newer builds): the newer edit's, plus keys only the other has.
/// - `savedAt` / `updatedAt`: the later of the two.
/// - purged marker: final. It beats any copy unless that copy was explicitly saved again
///   after the purge (`savedAt` > `purgedAt`); field edits never move `savedAt`.
public enum FastTabListMerge {
    public static func merge(_ a: SavedOnIPhoneLink, _ b: SavedOnIPhoneLink) -> SavedOnIPhoneLink {
        if a.isPurged || b.isPurged { return mergeWithPurge(a, b) }
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

        let readAgainSource = newer(a, b, by: {
            ($0.readAgainUpdatedAt ?? $0.readAgainAt ?? .distantPast,
             ($0.readAgainAt ?? .distantPast).timeIntervalSinceReferenceDate)
        })
        merged.readAgainAt = readAgainSource.readAgainAt
        merged.readAgainUpdatedAt = readAgainSource.readAgainUpdatedAt

        let countSource = newer(a, b, by: {
            ($0.readCountUpdatedAt ?? .distantPast, Double($0.readCount))
        }, preferringLarger: \.readCount)
        merged.readCount = countSource.readCount
        merged.readCountUpdatedAt = countSource.readCountUpdatedAt

        merged.unknownFields = mergedUnknownFields(a, b)
        return merged
    }

    /// Fields from newer builds: the newer edit's values, plus keys only the other copy has.
    /// Same `updatedAt` → per key, the larger canonical text (order-independent).
    private static func mergedUnknownFields(_ a: SavedOnIPhoneLink, _ b: SavedOnIPhoneLink) -> [String: OpaqueJSON] {
        if a.unknownFields.isEmpty && b.unknownFields.isEmpty { return [:] }
        if a.updatedAt != b.updatedAt {
            let (newer, older) = a.updatedAt > b.updatedAt ? (a, b) : (b, a)
            return newer.unknownFields.merging(older.unknownFields) { mine, _ in mine }
        }
        return a.unknownFields.merging(b.unknownFields) { x, y in x.canonicalText >= y.canonicalText ? x : y }
    }

    private static func mergeWithPurge(_ a: SavedOnIPhoneLink, _ b: SavedOnIPhoneLink) -> SavedOnIPhoneLink {
        let purgedAt = max(a.purgedAt ?? .distantPast, b.purgedAt ?? .distantPast)
        // At most one side is live here (the other is a marker).
        if let resaved = [a, b].first(where: { !$0.isPurged && $0.savedAt > purgedAt }) { return resaved }
        return .purgedMarker(id: a.id, purgedAt: purgedAt)
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

    /// The copy with the larger `primary` value; equal → `newer(by:)`.
    private static func newer(
        _ a: SavedOnIPhoneLink, _ b: SavedOnIPhoneLink, by key: (SavedOnIPhoneLink) -> (Date, Double),
        preferringLarger primary: (SavedOnIPhoneLink) -> Int
    ) -> SavedOnIPhoneLink {
        let pa = primary(a), pb = primary(b)
        if pa != pb { return pa > pb ? a : b }
        return newer(a, b, by: key)
    }
}
