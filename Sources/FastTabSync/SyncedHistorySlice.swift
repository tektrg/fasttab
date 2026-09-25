import Foundation
import CloudKit

public struct SyncedHistoryEntry: Identifiable, Codable, Hashable, Sendable {
    public var id: String { "\(url)|\(lastVisitedAt.timeIntervalSince1970)" }
    public let title: String
    public let url: String
    public let lastVisitedAt: Date

    public init(
        title: String,
        url: String,
        lastVisitedAt: Date
    ) {
        self.title = title
        self.url = url
        self.lastVisitedAt = lastVisitedAt
    }
}

public struct SyncedHistorySlice: Identifiable, Codable, Hashable, Sendable {
    public let id: String // e.g. "device_chrome_history"
    public let deviceID: String
    public let browserName: String
    public let updatedAt: Date
    public let entries: [SyncedHistoryEntry]

    public init(
        deviceID: String,
        browserName: String,
        entries: [SyncedHistoryEntry],
        updatedAt: Date = Date()
    ) {
        self.id = "\(deviceID)|\(browserName)|history"
        self.deviceID = deviceID
        self.browserName = browserName
        self.updatedAt = updatedAt
        self.entries = entries
    }

    public init(
        id: String,
        deviceID: String,
        browserName: String,
        updatedAt: Date,
        entries: [SyncedHistoryEntry]
    ) {
        self.id = id
        self.deviceID = deviceID
        self.browserName = browserName
        self.updatedAt = updatedAt
        self.entries = entries
    }
}

extension SyncedHistorySlice {
    public static let recordType = "SyncedHistorySlice"

    public init?(from record: CKRecord) {
        guard record.recordType == Self.recordType else { return nil }
        guard let deviceID = record["deviceID"] as? String,
              let browserName = record["browserName"] as? String,
              let updatedAt = record["updatedAt"] as? Date else {
            return nil
        }

        // Encrypted history data
        guard let encryptedData = record.encryptedValues["historyData"] as? Data,
              let entries = try? JSONDecoder().decode([SyncedHistoryEntry].self, from: encryptedData) else {
            return nil
        }

        self.id = record.recordID.recordName
        self.deviceID = deviceID
        self.browserName = browserName
        self.updatedAt = updatedAt
        self.entries = entries
    }

    public func toRecord(zoneID: CKRecordZone.ID) -> CKRecord? {
        guard let data = try? JSONEncoder().encode(entries) else { return nil }

        let recordID = CKRecord.ID(recordName: id, zoneID: zoneID)
        let record = CKRecord(recordType: Self.recordType, recordID: recordID)

        record["deviceID"] = deviceID as NSString
        record["browserName"] = browserName as NSString
        record["updatedAt"] = updatedAt as NSDate

        // Encrypted data
        record.encryptedValues["historyData"] = data as NSData

        return record
    }
}
