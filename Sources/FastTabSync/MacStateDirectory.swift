import Foundation
import CloudKit

// The history-free fast path from a Mac's live state to a phone.
//
// A phone learns what is in `StateZone` by reading the zone's change history. The
// Mac churns that zone all day (tabs opening and closing, a heartbeat every 3 min),
// and a read from scratch pages through every past change, not just the records
// that exist now: ~215 pages / minutes for ~56 live records (measured on the Mac,
// see `StateZoneMirror`). A fresh phone, which only syncs while on screen, showed
// "no Mac" for that long.
//
// So each Mac also keeps one small list of the state-zone records it has live
// right now. The phone fetches the list by its fixed ID, then the listed records by
// ID — two short round trips, no history. The history sync keeps running underneath
// and stays the authority for deletes (`DirectSnapshotPrecedence`).

/// One Mac's line in the directory.
public struct MacStateDirectoryEntry: Codable, Hashable, Sendable {
    public let deviceID: String
    public let deviceName: String
    /// When this Mac last wrote its entry. Coarse (see
    /// `MacStateDirectory.livenessRefreshInterval`): the phone reads the Mac's
    /// real "last seen" from its device record, which is listed in `recordNames`.
    public let lastSeenAt: Date
    /// Names of this Mac's live records in `StateZone`: sorted, unique, and always
    /// including the Mac's own device record (`deviceID`).
    public let recordNames: [String]

    public init<Names: Sequence<String>>(deviceID: String, deviceName: String, lastSeenAt: Date, recordNames: Names) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.lastSeenAt = lastSeenAt
        self.recordNames = Set(recordNames).union([deviceID]).sorted()
    }

    /// Same Mac, same name, same records: nothing a phone would act on changed.
    public func hasSameContent(as other: MacStateDirectoryEntry) -> Bool {
        deviceID == other.deviceID && deviceName == other.deviceName && recordNames == other.recordNames
    }

    private enum CodingKeys: String, CodingKey { case deviceID, deviceName, lastSeenAt, recordNames }

    /// Lenient: only the device id is required, so a future field or a missing
    /// optional one never makes a whole Mac disappear from the list.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let deviceID = try container.decode(String.self, forKey: .deviceID)
        self.init(
            deviceID: deviceID,
            deviceName: try container.decodeIfPresent(String.self, forKey: .deviceName) ?? "Mac",
            lastSeenAt: try container.decodeIfPresent(Date.self, forKey: .lastSeenAt) ?? .distantPast,
            recordNames: try container.decodeIfPresent([String].self, forKey: .recordNames) ?? []
        )
    }
}

/// Every Mac's entry, in ONE record with a fixed name in its own zone.
///
/// - One record, not one per Mac: a fresh phone knows no Mac's id, and fetching
///   by ID needs the name up front (a `CKQuery` would need indexes this container
///   does not define). Several Macs share it safely: each replaces only its own
///   entry, on top of the server copy (`merging`), with a change-tag-checked save.
/// - Its own zone (`DirectoryZone`), not `StateZone`: its writes add nothing to the
///   history every phone walks, and nothing ever reads this zone's history.
public struct MacStateDirectory: Hashable, Sendable {
    public static let zoneName = "DirectoryZone"
    public static let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    public static let recordType = "MacStateDirectory"
    public static let recordName = "macs"
    public static var recordID: CKRecord.ID { CKRecord.ID(recordName: recordName, zoneID: zoneID) }
    /// Encrypted like tab titles: device names and tab ids stay private to the account.
    static let payloadField = "entriesData"
    static let currentVersion = 1

    /// Another Mac silent this long is dropped by whichever Mac writes next.
    public static let retention: TimeInterval = 90 * 24 * 60 * 60
    /// An unchanged entry is still rewritten this often, so a live Mac never ages out.
    public static let livenessRefreshInterval: TimeInterval = 6 * 60 * 60
    /// At most one write per this interval: tab churn coalesces into one write.
    public static let minimumWriteSpacing: TimeInterval = 60
    /// Short wait so a burst of acks (one tab sync = many records) becomes one write.
    public static let writeDebounce: TimeInterval = 5
    public static let maxRetryBackoff: TimeInterval = 30 * 60

    public private(set) var entries: [MacStateDirectoryEntry]

    public init(entries: [MacStateDirectoryEntry] = []) {
        self.entries = entries.sorted { $0.deviceID < $1.deviceID }
    }

    public func entry(for deviceID: String) -> MacStateDirectoryEntry? {
        entries.first { $0.deviceID == deviceID }
    }

    /// This directory with `own` replacing this Mac's entry, and other Macs
    /// unheard of for `retention` dropped.
    public func merging(_ own: MacStateDirectoryEntry, now: Date, retention: TimeInterval = retention) -> MacStateDirectory {
        let others = entries.filter {
            $0.deviceID != own.deviceID && now.timeIntervalSince($0.lastSeenAt) < retention
        }
        return MacStateDirectory(entries: others + [own])
    }

    /// Whether the Mac must rewrite its entry: first time, the record set or name
    /// changed, or the liveness refresh is due. Nothing else — a heartbeat alone is
    /// not a reason (the phone reads "last seen" from the device record).
    public static func shouldWrite(
        published: MacStateDirectoryEntry?,
        desired: MacStateDirectoryEntry,
        now: Date,
        livenessRefresh: TimeInterval = livenessRefreshInterval
    ) -> Bool {
        guard let published else { return true }
        if !published.hasSameContent(as: desired) { return true }
        return now.timeIntervalSince(published.lastSeenAt) >= livenessRefresh
    }

    /// How long to wait before the next write attempt.
    public static func writeDelay(lastWriteAt: Date?, retryAfter: Date?, now: Date) -> TimeInterval {
        var delay = writeDebounce
        if let lastWriteAt {
            delay = max(delay, minimumWriteSpacing - now.timeIntervalSince(lastWriteAt))
        }
        if let retryAfter {
            delay = max(delay, retryAfter.timeIntervalSince(now))
        }
        return delay
    }

    /// 1 min, 2 min, 4 min … capped: a Mac whose writes keep failing (e.g. the
    /// record type is not in the Production schema yet) must not hammer CloudKit.
    public static func retryBackoff(afterFailures failures: Int) -> TimeInterval {
        let exponent = Double(min(max(failures - 1, 0), 16))
        return min(minimumWriteSpacing * pow(2, exponent), maxRetryBackoff)
    }

    /// Whether a `StateZone` record name belongs to the Mac `deviceID`. Every
    /// record type a Mac publishes there is named after its device id:
    /// `SyncedDevice` = id, tabs `{id}_…`, bookmarks/history/stats/favicons
    /// `{id}|…`, tab order `tab_order_{id}`. Device ids are UUIDs, so a prefix
    /// can never collide.
    public static func isOwnedStateRecordName(_ name: String, deviceID: String) -> Bool {
        name == deviceID
            || name.hasPrefix(deviceID + "_")
            || name.hasPrefix(deviceID + "|")
            || name == "tab_order_\(deviceID)"
    }
}

// MARK: - Payload + CloudKit

extension MacStateDirectory {
    private struct Payload: Codable {
        var version: Int
        var entries: [LossyEntry]
    }

    /// Decodes to nil instead of throwing, so one bad entry drops only itself.
    private struct LossyEntry: Codable {
        let value: MacStateDirectoryEntry?
        init(_ value: MacStateDirectoryEntry) { self.value = value }
        init(from decoder: Decoder) throws { value = try? MacStateDirectoryEntry(from: decoder) }
        func encode(to encoder: Encoder) throws { try value?.encode(to: encoder) }
    }

    public func encodedPayload() throws -> Data {
        try JSONEncoder().encode(Payload(version: Self.currentVersion, entries: entries.map(LossyEntry.init)))
    }

    public static func decodePayload(_ data: Data) -> MacStateDirectory? {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        return MacStateDirectory(entries: payload.entries.compactMap(\.value))
    }

    public init?(from record: CKRecord) {
        guard record.recordType == Self.recordType,
              let data = record.encryptedValues[Self.payloadField] as? Data,
              let decoded = Self.decodePayload(data) else { return nil }
        self = decoded
    }

    /// A blank record at the fixed ID. Saving it over an existing one fails with
    /// `serverRecordChanged`, which carries the server copy to merge into.
    public static func newRecord() -> CKRecord {
        CKRecord(recordType: recordType, recordID: recordID)
    }

    public func applying(to record: CKRecord) -> CKRecord? {
        guard record.recordType == Self.recordType,
              record.recordID == Self.recordID,
              let payload = try? encodedPayload() else { return nil }
        record.encryptedValues[Self.payloadField] = payload as NSData
        return record
    }
}

// MARK: - Mac: which of its records exist on the server

/// This Mac's own `StateZone` record names that CloudKit confirmed: added on a
/// save ack, removed on a delete ack, and re-based on the state-zone mirror
/// whenever it catches up (which also covers records published before this
/// ledger existed). Persisted by the Mac between launches.
public struct OwnedStateRecordLedger: Codable, Equatable, Sendable {
    public private(set) var recordNames: Set<String>
    /// Acks that land while a mirror catch-up runs: newer than the mirror's view.
    private var resync: Resync?

    private struct Resync: Equatable, Sendable {
        var saved: Set<String> = []
        var deleted: Set<String> = []
    }

    private enum CodingKeys: String, CodingKey { case recordNames }

    public init(recordNames: Set<String> = []) {
        self.recordNames = recordNames
    }

    public mutating func noteSaved<Names: Sequence<String>>(_ names: Names) {
        for name in names {
            recordNames.insert(name)
            resync?.saved.insert(name)
            resync?.deleted.remove(name)
        }
    }

    public mutating func noteDeleted<Names: Sequence<String>>(_ names: Names) {
        for name in names {
            recordNames.remove(name)
            resync?.deleted.insert(name)
            resync?.saved.remove(name)
        }
    }

    /// Call before the mirror catch-up starts. A resync already running keeps its journal.
    public mutating func beginResync() {
        if resync == nil { resync = Resync() }
    }

    /// The mirror reached the present: its view, corrected by acks since `beginResync`.
    public mutating func finishResync<Names: Sequence<String>>(serverRecordNames: Names) {
        guard let resync else { return }
        recordNames = Set(serverRecordNames).union(resync.saved).subtracting(resync.deleted)
        self.resync = nil
    }

    public mutating func cancelResync() { resync = nil }

    public mutating func reset() {
        recordNames.removeAll()
        resync = nil
    }
}

// MARK: - Phone: what to fetch, and what may be applied

public enum MacDirectoryFetchPlan {
    /// How often an on-screen phone re-reads the directory (one tiny record) and
    /// every Mac's device record.
    public static let checkInterval: TimeInterval = 30
    /// Records per fetch request (CloudKit allows up to 400 items per operation).
    public static let batchSize = 150

    /// `full`: every listed record (launch, pull-to-refresh). Otherwise only the
    /// records not fetched yet this launch, plus each Mac's device record so "last
    /// seen" stays current. Updates to records already shown arrive via the history sync.
    public static func recordNames(in directory: MacStateDirectory, alreadyFetched: Set<String>, full: Bool) -> [String] {
        var names: [String] = []
        var seen: Set<String> = []
        for entry in directory.entries {
            for name in entry.recordNames where full || name == entry.deviceID || !alreadyFetched.contains(name) {
                if seen.insert(name).inserted { names.append(name) }
            }
        }
        return names
    }

    public static func batches(_ names: [String], size: Int = batchSize) -> [[String]] {
        stride(from: 0, to: names.count, by: max(size, 1)).map {
            Array(names[$0..<min($0 + max(size, 1), names.count)])
        }
    }
}

/// Keeps the direct snapshot from fighting the history-based sync on the phone.
///
/// - The history sync (CKSyncEngine fetch + zone sweep) is the authority. It is
///   always applied, and deletes anything.
/// - A direct copy is applied only if it is newer (server modification date) than
///   what either path last applied for that record, so a slow fetch cannot roll a
///   record back.
/// - The direct path removes only records it alone has shown, once a newer
///   directory stops listing them (`directOnlyNamesDropped`).
/// - A record the history sync deleted is never re-added by a direct copy — not
///   even a "newer" one fetched across the delete — until the history sync itself
///   delivers the record again (a reused tab record name). Without this a direct
///   fetch in flight across a delete would resurrect a closed tab for good: the
///   history token has already moved past the delete.
public struct DirectSnapshotPrecedence: Sendable {
    private var lastAppliedModifiedAt: [String: Date] = [:]
    private var deletedByHistory: Set<String> = []
    /// Shown by the direct path and not touched by the history sync since, with the
    /// modification date of the version shown (see `directOnlyNamesDropped`).
    private var directOnlyModifiedAt: [String: Date] = [:]

    public init() {}

    public mutating func noteHistoryApplied(modified: [(name: String, modifiedAt: Date?)], deleted: [String]) {
        for (name, modifiedAt) in modified {
            deletedByHistory.remove(name)
            directOnlyModifiedAt.removeValue(forKey: name)
            // A dateless record still counts as applied (oldest possible version).
            lastAppliedModifiedAt[name] = modifiedAt ?? .distantPast
        }
        for name in deleted {
            deletedByHistory.insert(name)
            directOnlyModifiedAt.removeValue(forKey: name)
            lastAppliedModifiedAt.removeValue(forKey: name)
        }
    }

    public func admitsDirect(recordName: String, modifiedAt: Date?) -> Bool {
        guard !deletedByHistory.contains(recordName) else { return false }
        guard let applied = lastAppliedModifiedAt[recordName] else { return true }
        guard let modifiedAt else { return false }
        return modifiedAt > applied
    }

    public mutating func noteDirectApplied(recordName: String, modifiedAt: Date?) {
        lastAppliedModifiedAt[recordName] = modifiedAt ?? .distantPast
        directOnlyModifiedAt[recordName] = modifiedAt ?? .distantPast
    }

    /// Records only the direct path has shown that the directory, written after the
    /// shown version, no longer lists: the Mac deleted them. On a fresh install the
    /// history sync would take minutes to deliver those deletes, leaving closed tabs
    /// on screen. Conservative: never a record the history sync has seen (it owns
    /// that record now), never one whose Mac is missing from the directory, and
    /// never on a directory not provably newer than the shown version.
    public func directOnlyNamesDropped(by directory: MacStateDirectory, directoryModifiedAt: Date?) -> [String] {
        guard let directoryModifiedAt else { return [] }
        return directOnlyModifiedAt.compactMap { name, shownModifiedAt -> String? in
            guard directoryModifiedAt > shownModifiedAt,
                  let owner = directory.entries.first(where: {
                      MacStateDirectory.isOwnedStateRecordName(name, deviceID: $0.deviceID)
                  }),
                  !owner.recordNames.contains(name) else { return nil }
            return name
        }.sorted()
    }

    /// After removing dropped records from the cache: forgotten, not tombstoned, so
    /// a later listing (a re-used tab record name) may fetch and show them again.
    public mutating func forgetDirectOnly<Names: Sequence<String>>(_ names: Names) {
        for name in names {
            directOnlyModifiedAt.removeValue(forKey: name)
            lastAppliedModifiedAt.removeValue(forKey: name)
        }
    }

    public mutating func reset() {
        lastAppliedModifiedAt.removeAll()
        deletedByHistory.removeAll()
        directOnlyModifiedAt.removeAll()
    }
}
