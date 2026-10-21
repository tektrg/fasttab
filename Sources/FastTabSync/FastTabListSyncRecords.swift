import CloudKit
import Foundation

/// One FastTab List item in CloudKit (`ReaderZone`). Record name = `li|` + the item id
/// (derived from the canonical URL), so the same link saved on two devices is one record.
/// The body is the item's JSON (sorted keys), encrypted; new fields are additive.
public struct SyncedListItem: Hashable, Sendable {
    public static let recordType = "FastTabListItem"
    static let namePrefix = "li|"

    public let item: SavedOnIPhoneLink

    public init(_ item: SavedOnIPhoneLink) {
        self.item = item
    }

    public var recordName: String { Self.recordName(forItemID: item.id) }

    public static func recordName(forItemID id: String) -> String { namePrefix + id }

    public init?(from record: CKRecord) {
        guard record.recordType == Self.recordType,
              record.recordID.recordName.hasPrefix(Self.namePrefix),
              let payload = record.encryptedValues["payload"] as? Data,
              var item = try? JSONDecoder().decode(SavedOnIPhoneLink.self, from: payload) else { return nil }
        // The record name is the identity; never trust a payload id that disagrees.
        item.id = String(record.recordID.recordName.dropFirst(Self.namePrefix.count))
        self.init(item)
    }

    /// Canonical bytes: equal items always encode (and hash) equal.
    public var payload: Data {
        (try? Self.encoder.encode(item)) ?? Data()
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    public func toRecord(zoneID: CKRecordZone.ID) -> CKRecord {
        applying(to: CKRecord(recordType: Self.recordType, recordID: CKRecord.ID(recordName: recordName, zoneID: zoneID)))
    }

    /// Writes this item onto `record` (a fresh one, or the server copy after a conflict).
    public func applying(to record: CKRecord) -> CKRecord {
        record.encryptedValues["payload"] = payload as NSData
        return record
    }
}
