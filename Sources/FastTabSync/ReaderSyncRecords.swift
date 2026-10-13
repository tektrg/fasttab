import CloudKit
import CryptoKit
import Foundation

/// One reader highlight in CloudKit (`ReaderZone`). The body is the phone's `ReaderHighlight`
/// JSON, carried opaquely so the Mac needs no copy of that type; edits (tags, thread link)
/// replace it, last write wins.
public struct SyncedReaderHighlight: Hashable, Sendable {
    public static let recordType = "SyncedReaderHighlight"
    static let namePrefix = "hl|"

    public let id: String
    /// The article's canonical URL (`readerCanonicalKey`).
    public let urlKey: String
    /// `ReaderHighlight` encoded with sorted keys, so equal highlights hash equal.
    public let payload: Data

    public init(id: String, urlKey: String, payload: Data) {
        self.id = id
        self.urlKey = urlKey
        self.payload = payload
    }

    public var recordName: String { Self.namePrefix + id }

    public init?(from record: CKRecord) {
        guard record.recordType == Self.recordType,
              record.recordID.recordName.hasPrefix(Self.namePrefix),
              let urlKey = record.encryptedValues["urlKey"] as? String,
              let payload = record.encryptedValues["payload"] as? Data else { return nil }
        self.init(id: String(record.recordID.recordName.dropFirst(Self.namePrefix.count)), urlKey: urlKey, payload: payload)
    }

    public func toRecord(zoneID: CKRecordZone.ID) -> CKRecord {
        applying(to: CKRecord(recordType: Self.recordType, recordID: CKRecord.ID(recordName: recordName, zoneID: zoneID)))
    }

    /// Writes these fields onto `record` (a fresh one, or the server copy after a conflict).
    public func applying(to record: CKRecord) -> CKRecord {
        record.encryptedValues["urlKey"] = urlKey as NSString
        record.encryptedValues["payload"] = payload as NSData
        return record
    }
}

/// One comment event (IndieComments, MDLY's format) in CloudKit. Events never change once
/// written, so these records are only ever created, never edited or deleted.
public struct SyncedCommentEvent: Hashable, Sendable {
    public static let recordType = "SyncedCommentEvent"
    static let namePrefix = "ce|"

    public let eventID: String
    /// The comment log the event belongs to (one per article).
    public let docId: String
    /// The event as one JSON line, sorted keys.
    public let payload: Data

    public init(eventID: String, docId: String, payload: Data) {
        self.eventID = eventID
        self.docId = docId
        self.payload = payload
    }

    public var recordName: String { Self.namePrefix + eventID }

    public init?(from record: CKRecord) {
        guard record.recordType == Self.recordType,
              record.recordID.recordName.hasPrefix(Self.namePrefix),
              let docId = record.encryptedValues["docId"] as? String,
              let payload = record.encryptedValues["payload"] as? Data else { return nil }
        self.init(eventID: String(record.recordID.recordName.dropFirst(Self.namePrefix.count)), docId: docId, payload: payload)
    }

    public func toRecord(zoneID: CKRecordZone.ID) -> CKRecord {
        let record = CKRecord(recordType: Self.recordType, recordID: CKRecord.ID(recordName: recordName, zoneID: zoneID))
        record.encryptedValues["docId"] = docId as NSString
        record.encryptedValues["payload"] = payload as NSData
        return record
    }
}

/// The log name for an article's comments: its canonical URL hashed (URLs are not file
/// names). Shared so the phone and the Mac file an article's comments under the same name.
public enum ReaderCommentDocID {
    public static func forArticle(urlKey: String) -> String {
        SHA256.hash(data: Data(urlKey.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
