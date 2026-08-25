import Foundation

/// One destination the user has picked in the move sheet before, and how
/// often/recently. Bucketed by `deviceID` because a destination is only ever
/// valid on the *same Mac* as the bookmark being moved (see `BookmarkMovePicker`)
/// — mixing devices here would let a different Mac's folder rank as "frequent"
/// for a bookmark it can never actually be moved to.
struct BookmarkMoveDestinationRecord: Codable, Equatable {
    let deviceID: String
    let browserName: String
    let profileName: String
    /// `[]` means top level.
    let folderPath: [String]
    var selectionCount: Int
    var lastSelectedAt: Date
}

/// Local-only (never synced) history of move destinations the user has picked,
/// purely to power the picker's "Frequent"/"Recent" shortcuts. Deliberately not
/// folded into `LocalCache`/`CachedSyncState` — that type is documented as
/// CloudKit-synced state only. `UserDefaults.standard` mirrors the existing
/// precedent for small local-only state (`SyncConsumer`'s device-id key).
enum BookmarkMoveDestinationHistory {
    private static let defaultsKey = "FastTabMobile.bookmarkMoveDestinationHistoryV1"

    /// Bounds storage growth. Sized well above what "top 3" will ever need —
    /// this only trims runaway growth, it never affects ranking below that size.
    private static let maxStoredRecords = 100

    private static func load() -> [BookmarkMoveDestinationRecord] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let records = try? JSONDecoder().decode([BookmarkMoveDestinationRecord].self, from: data) else {
            return []
        }
        return records
    }

    private static func save(_ records: [BookmarkMoveDestinationRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    /// Call the moment the user taps a destination in the picker — counts the
    /// selection itself, not whether the move that follows later succeeds.
    static func recordSelection(deviceID: String, browserName: String, profileName: String, folderPath: [String]) {
        var records = load()
        let now = Date()
        if let index = records.firstIndex(where: {
            $0.deviceID == deviceID && $0.browserName == browserName
                && $0.profileName == profileName && $0.folderPath == folderPath
        }) {
            records[index].selectionCount += 1
            records[index].lastSelectedAt = now
        } else {
            records.append(BookmarkMoveDestinationRecord(
                deviceID: deviceID, browserName: browserName, profileName: profileName,
                folderPath: folderPath, selectionCount: 1, lastSelectedAt: now
            ))
        }

        if records.count > maxStoredRecords {
            records.sort { $0.lastSelectedAt > $1.lastSelectedAt }
            records = Array(records.prefix(maxStoredRecords))
        }
        save(records)
    }

    /// Top destinations for `deviceID` by selection count, most-selected first.
    /// Ties broken by most-recent, so a fresh tie doesn't look arbitrarily ordered.
    static func topFrequent(deviceID: String, limit: Int) -> [BookmarkMoveDestinationRecord] {
        load()
            .filter { $0.deviceID == deviceID }
            .sorted {
                $0.selectionCount != $1.selectionCount
                    ? $0.selectionCount > $1.selectionCount
                    : $0.lastSelectedAt > $1.lastSelectedAt
            }
            .prefix(limit)
            .map { $0 }
    }

    /// Top destinations for `deviceID` by last-selected time, most-recent first.
    static func topRecent(deviceID: String, limit: Int) -> [BookmarkMoveDestinationRecord] {
        load()
            .filter { $0.deviceID == deviceID }
            .sorted { $0.lastSelectedAt > $1.lastSelectedAt }
            .prefix(limit)
            .map { $0 }
    }
}
