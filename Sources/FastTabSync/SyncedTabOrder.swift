import Foundation
import CloudKit
import CryptoKit

public struct SyncedOrderedSlot: Codable, Hashable, Sendable {
    public let slotID: UUID
    public let matchKey: String
    public let title: String
    public let url: String
    public let browserName: String
    public let profileName: String?
    public let state: String
    public let ghostedAt: Date?
    public let isPinned: Bool

    enum CodingKeys: String, CodingKey {
        case slotID, matchKey, title, url, browserName, profileName, state, ghostedAt, isPinned
    }

    public init(
        slotID: UUID,
        matchKey: String,
        title: String,
        url: String,
        browserName: String,
        profileName: String?,
        state: String,
        ghostedAt: Date?,
        isPinned: Bool = false
    ) {
        self.slotID = slotID
        self.matchKey = matchKey
        self.title = title
        self.url = url
        self.browserName = browserName
        self.profileName = profileName
        self.state = state
        self.ghostedAt = ghostedAt
        self.isPinned = isPinned
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.slotID = try container.decode(UUID.self, forKey: .slotID)
        self.matchKey = try container.decode(String.self, forKey: .matchKey)
        self.title = try container.decode(String.self, forKey: .title)
        self.url = try container.decode(String.self, forKey: .url)
        self.browserName = try container.decode(String.self, forKey: .browserName)
        self.profileName = try container.decodeIfPresent(String.self, forKey: .profileName)
        self.state = try container.decode(String.self, forKey: .state)
        self.ghostedAt = try container.decodeIfPresent(Date.self, forKey: .ghostedAt)
        self.isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(slotID, forKey: .slotID)
        try container.encode(matchKey, forKey: .matchKey)
        try container.encode(title, forKey: .title)
        try container.encode(url, forKey: .url)
        try container.encode(browserName, forKey: .browserName)
        try container.encodeIfPresent(profileName, forKey: .profileName)
        try container.encode(state, forKey: .state)
        try container.encodeIfPresent(ghostedAt, forKey: .ghostedAt)
        try container.encode(isPinned, forKey: .isPinned)
    }
}

public struct SyncedTabOrder: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let deviceID: String
    public let contentHash: String
    public let updatedAt: Date
    public let slots: [SyncedOrderedSlot]

    public init(
        deviceID: String,
        slots: [SyncedOrderedSlot],
        updatedAt: Date = Date()
    ) {
        self.id = "tab_order_\(deviceID)"
        self.deviceID = deviceID
        self.updatedAt = updatedAt
        self.slots = slots

        // SHA256 of canonical encoded slots
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = (try? encoder.encode(slots)) ?? Data()
        let digest = SHA256.hash(data: data)
        self.contentHash = digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    public init(
        id: String,
        deviceID: String,
        contentHash: String,
        updatedAt: Date,
        slots: [SyncedOrderedSlot]
    ) {
        self.id = id
        self.deviceID = deviceID
        self.contentHash = contentHash
        self.updatedAt = updatedAt
        self.slots = slots
    }
}

extension SyncedTabOrder {
    public static let recordType = "SyncedTabOrder"

    public init?(from record: CKRecord) {
        guard record.recordType == Self.recordType else { return nil }
        guard let deviceID = record["deviceID"] as? String,
              let contentHash = record["contentHash"] as? String,
              let updatedAt = record["updatedAt"] as? Date else {
            return nil
        }

        guard let encryptedData = record.encryptedValues["slotsData"] as? Data,
              let slots = try? JSONDecoder().decode([SyncedOrderedSlot].self, from: encryptedData) else {
            return nil
        }

        self.id = record.recordID.recordName
        self.deviceID = deviceID
        self.contentHash = contentHash
        self.updatedAt = updatedAt
        self.slots = slots
    }

    public func toRecord(zoneID: CKRecordZone.ID) -> CKRecord {
        let recordID = CKRecord.ID(recordName: id, zoneID: zoneID)
        return writeFields(into: CKRecord(recordType: Self.recordType, recordID: recordID))
    }

    /// Writes this order onto an existing (server) record so a save carries its
    /// change tag. Saving a fresh `toRecord` over a record that already exists
    /// fails with "record to insert already exists". Nil when the record is not
    /// this order's.
    public func applying(to record: CKRecord) -> CKRecord? {
        guard record.recordType == Self.recordType,
              record.recordID.recordName == id else { return nil }
        return writeFields(into: record)
    }

    private func writeFields(into record: CKRecord) -> CKRecord {
        record["deviceID"] = deviceID as CKRecordValue
        record["contentHash"] = contentHash as CKRecordValue
        record["updatedAt"] = updatedAt as CKRecordValue

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = (try? encoder.encode(slots)) ?? Data()
        record.encryptedValues["slotsData"] = data as CKRecordValue
        return record
    }
}
