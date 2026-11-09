import CloudKit
import CryptoKit
import Foundation

/// Where the user is in one article read on a phone, whether or not it is in the FastTab List:
/// the **reading activity** the Mac's reading connector reports ("what did I read this week").
/// One per canonical URL; `id` is `FastTabListLibrary.itemID(for:)`, so a list item and its
/// activity share an id.
public struct ReadingActivity: Codable, Hashable, Sendable {
    public var id: String
    public var url: String
    public var title: String?
    /// Scroll fraction 0...1.
    public var progress: Double
    /// When progress last changed (the merge key: newest wins).
    public var lastReadAt: Date

    public init(url: String, title: String? = nil, progress: Double, lastReadAt: Date) {
        id = FastTabListLibrary.itemID(for: url)
        self.url = url
        self.title = title
        self.progress = max(0, min(1, progress))
        self.lastReadAt = lastReadAt
    }

    /// Newest `lastReadAt` wins; a title is never lost to a copy without one. Symmetric, so
    /// every device converges whatever order copies arrive in.
    public static func merge(_ a: ReadingActivity, _ b: ReadingActivity) -> ReadingActivity {
        var newer = (a.lastReadAt, a.progress, a.url) >= (b.lastReadAt, b.progress, b.url) ? a : b
        let older = newer == a ? b : a
        if newer.title?.isEmpty ?? true { newer.title = older.title }
        return newer
    }
}

/// One `ReadingActivity` in CloudKit (`ReaderZone`, record type `ReadingActivity`, name
/// `ra|<id>`). Body encrypted, sorted-key JSON. Only ever saved, never deleted: the phone's
/// local cap evicting an entry must not erase the history the Mac keeps.
public struct SyncedReadingActivity: Hashable, Sendable {
    public static let recordType = "ReadingActivity"
    static let namePrefix = "ra|"

    public let activity: ReadingActivity

    public init(_ activity: ReadingActivity) { self.activity = activity }

    public var recordName: String { Self.namePrefix + activity.id }

    public init?(from record: CKRecord) {
        guard record.recordType == Self.recordType,
              record.recordID.recordName.hasPrefix(Self.namePrefix),
              let payload = record.encryptedValues["payload"] as? Data,
              var activity = try? JSONDecoder().decode(ReadingActivity.self, from: payload) else { return nil }
        activity.id = String(record.recordID.recordName.dropFirst(Self.namePrefix.count))
        self.init(activity)
    }

    /// Canonical bytes: equal activities always encode (and hash) equal.
    public var payload: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(activity)) ?? Data()
    }

    public func toRecord(zoneID: CKRecordZone.ID) -> CKRecord {
        applying(to: CKRecord(recordType: Self.recordType, recordID: CKRecord.ID(recordName: recordName, zoneID: zoneID)))
    }

    public func applying(to record: CKRecord) -> CKRecord {
        record.encryptedValues["payload"] = payload as NSData
        return record
    }
}

/// Where a device keeps reading activity, as sync sees it.
@MainActor
public protocol ReadingActivitySyncStore: AnyObject {
    /// What this device sends (the Mac: nothing).
    func readingActivitiesForSync() -> [ReadingActivity]
    /// Other devices' copies (one fetch batch): merge them in.
    func applyRemoteReadingActivities(_ activities: [ReadingActivity])
}

/// Reading activity in step with `ReaderZone`, same ledger model as `FastTabListSyncBridge`
/// (no outbox; the ledger holds a hash of what CloudKit last confirmed per record), minus
/// deletes: activity is only ever saved.
@MainActor
public final class ReadingActivitySyncBridge {
    public let zoneID: CKRecordZone.ID
    private let store: ReadingActivitySyncStore
    private let ledgerURL: URL
    private var confirmed: [String: String]

    public init(ledgerURL: URL, store: ReadingActivitySyncStore, zoneID: CKRecordZone.ID = SyncConstants.readerZoneID) {
        self.ledgerURL = ledgerURL
        self.store = store
        self.zoneID = zoneID
        confirmed = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: ledgerURL))) ?? [:]
    }

    public static func handles(_ recordType: String) -> Bool { recordType == SyncedReadingActivity.recordType }

    public func pendingSaves() -> [CKRecord] {
        store.readingActivitiesForSync().map(SyncedReadingActivity.init)
            .filter { confirmed[$0.recordName] != ReaderSyncBridge.hash($0.payload) }
            .map { $0.toRecord(zoneID: zoneID) }
    }

    public func didSave(_ records: [CKRecord]) {
        var changed = false
        for record in records {
            guard let synced = SyncedReadingActivity(from: record) else { continue }
            confirmed[synced.recordName] = ReaderSyncBridge.hash(synced.payload)
            changed = true
        }
        if changed { saveLedger() }
    }

    public func outcome(ofFailedSave record: CKRecord, error: Error) -> ReaderSyncBridge.FailedSaveOutcome {
        guard Self.handles(record.recordType) else { return .notReader }
        guard let ckError = error as? CKError else { return .failed }
        switch ckError.code {
        case .serverRecordChanged:
            guard let serverRecord = ckError.serverRecord, let server = SyncedReadingActivity(from: serverRecord),
                  let mine = SyncedReadingActivity(from: record) else { return .failed }
            let merged = SyncedReadingActivity(ReadingActivity.merge(mine.activity, server.activity))
            store.applyRemoteReadingActivities([server.activity])
            confirmed[server.recordName] = ReaderSyncBridge.hash(server.payload)
            saveLedger()
            return merged.payload == server.payload ? .settled : .retry(merged.applying(to: serverRecord))
        case .unknownItem:
            return SyncedReadingActivity(from: record).map { .retry($0.toRecord(zoneID: zoneID)) } ?? .failed
        default:
            return .failed
        }
    }

    public func absorb(_ records: [CKRecord]) {
        let remotes = records.compactMap(SyncedReadingActivity.init(from:))
        guard !remotes.isEmpty else { return }
        store.applyRemoteReadingActivities(remotes.map(\.activity))
        for remote in remotes { confirmed[remote.recordName] = ReaderSyncBridge.hash(remote.payload) }
        saveLedger()
    }

    /// A different iCloud account: resend everything.
    public func resetLedger() {
        confirmed = [:]
        saveLedger()
    }

    private func saveLedger() {
        do {
            try FileManager.default.createDirectory(at: ledgerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(confirmed).write(to: ledgerURL, options: .atomic)
        } catch {
            // Losing the ledger only re-sends; merges make re-sends no-ops.
        }
    }
}

/// The Mac's on-disk copy of the phone's reading activity (`<support>/ReadingActivity/
/// activity.json`), written by the app's sync and read by the `fasttab-mcp` helper. Receive
/// only: the Mac never sends activity. Capped at `maxEntries`, oldest dropped.
@MainActor
public final class ReadingActivityMirror: ReadingActivitySyncStore {
    public static let maxEntries = 5_000
    public let fileURL: URL
    private var byID: [String: ReadingActivity]

    public init(fileURL: URL) {
        self.fileURL = fileURL
        byID = Dictionary(Self.load(fileURL: fileURL).map { ($0.id, $0) }, uniquingKeysWith: ReadingActivity.merge)
    }

    public nonisolated static func fileURL(supportDirectory: URL) -> URL {
        supportDirectory.appendingPathComponent("ReadingActivity", isDirectory: true)
            .appendingPathComponent("activity.json")
    }

    /// Newest first. Any process may read.
    public nonisolated static func load(fileURL: URL) -> [ReadingActivity] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return ((try? JSONDecoder().decode([ReadingActivity].self, from: data)) ?? [])
            .sorted { $0.lastReadAt > $1.lastReadAt }
    }

    public var activities: [ReadingActivity] { byID.values.sorted { $0.lastReadAt > $1.lastReadAt } }

    public func readingActivitiesForSync() -> [ReadingActivity] { [] }

    public func applyRemoteReadingActivities(_ incoming: [ReadingActivity]) {
        var changed = false
        for activity in incoming {
            let merged = byID[activity.id].map { ReadingActivity.merge($0, activity) } ?? activity
            guard merged != byID[activity.id] else { continue }
            byID[activity.id] = merged
            changed = true
        }
        if changed { save() }
    }

    private func save() {
        var list = activities
        if list.count > Self.maxEntries {
            list = Array(list.prefix(Self.maxEntries))
            byID = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(list).write(to: fileURL, options: .atomic)
        } catch {
            // The next fetch re-applies.
        }
    }
}
