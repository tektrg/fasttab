import Foundation
import CloudKit

public struct SyncedDevice: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let modelName: String
    public let lastSeenAt: Date
    public let appVersion: String

    public init(
        id: String,
        name: String,
        modelName: String,
        lastSeenAt: Date = Date(),
        appVersion: String
    ) {
        self.id = id
        self.name = name
        self.modelName = modelName
        self.lastSeenAt = lastSeenAt
        self.appVersion = appVersion
    }
}

extension SyncedDevice {
    public static let recordType = "SyncedDevice"

    public init?(from record: CKRecord) {
        guard record.recordType == Self.recordType else { return nil }
        guard let name = record["name"] as? String,
              let modelName = record["modelName"] as? String,
              let lastSeenAt = record["lastSeenAt"] as? Date,
              let appVersion = record["appVersion"] as? String else {
            return nil
        }
        self.id = record.recordID.recordName
        self.name = name
        self.modelName = modelName
        self.lastSeenAt = lastSeenAt
        self.appVersion = appVersion
    }

    public func toRecord(zoneID: CKRecordZone.ID) -> CKRecord {
        let recordID = CKRecord.ID(recordName: id, zoneID: zoneID)
        let record = CKRecord(recordType: Self.recordType, recordID: recordID)
        record["name"] = name as NSString
        record["modelName"] = modelName as NSString
        record["lastSeenAt"] = lastSeenAt as NSDate
        record["appVersion"] = appVersion as NSString
        return record
    }
}
