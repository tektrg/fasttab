import Foundation
import CloudKit

public struct SyncedTab: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let deviceID: String
    public let browserName: String
    public let title: String
    public let url: String
    public let timestamp: Date
    public let windowIndex: Int?
    public let tabIndex: Int?
    public let windowName: String?
    public let tabID: Int?
    public let isAudible: Bool
    public let isMuted: Bool
    public let isPinned: Bool
    public let isDiscarded: Bool
    public let tabGroupTitle: String?
    public let profileName: String?

    public init(
        id: String,
        deviceID: String,
        browserName: String,
        title: String,
        url: String,
        timestamp: Date = Date(),
        windowIndex: Int? = nil,
        tabIndex: Int? = nil,
        windowName: String? = nil,
        tabID: Int? = nil,
        isAudible: Bool = false,
        isMuted: Bool = false,
        isPinned: Bool = false,
        isDiscarded: Bool = false,
        tabGroupTitle: String? = nil,
        profileName: String? = nil
    ) {
        self.id = id
        self.deviceID = deviceID
        self.browserName = browserName
        self.title = title
        self.url = url
        self.timestamp = timestamp
        self.windowIndex = windowIndex
        self.tabIndex = tabIndex
        self.windowName = windowName
        self.tabID = tabID
        self.isAudible = isAudible
        self.isMuted = isMuted
        self.isPinned = isPinned
        self.isDiscarded = isDiscarded
        self.tabGroupTitle = tabGroupTitle
        self.profileName = profileName
    }
}

extension SyncedTab {
    public static let recordType = "SyncedTab"

    public init?(from record: CKRecord) {
        guard record.recordType == Self.recordType else { return nil }
        guard let deviceID = record["deviceID"] as? String,
              let browserName = record["browserName"] as? String,
              let timestamp = record["timestamp"] as? Date else {
            return nil
        }

        // Read end-to-end encrypted values
        let enc = record.encryptedValues
        guard let title = enc["title"] as? String,
              let url = enc["url"] as? String else {
            return nil
        }

        self.id = record.recordID.recordName
        self.deviceID = deviceID
        self.browserName = browserName
        self.title = title
        self.url = url
        self.timestamp = timestamp
        self.windowIndex = (record["windowIndex"] as? NSNumber)?.intValue
        self.tabIndex = (record["tabIndex"] as? NSNumber)?.intValue
        self.windowName = enc["windowName"] as? String
        self.tabID = (record["tabID"] as? NSNumber)?.intValue
        self.isAudible = (record["isAudible"] as? NSNumber)?.boolValue ?? false
        self.isMuted = (record["isMuted"] as? NSNumber)?.boolValue ?? false
        self.isPinned = (record["isPinned"] as? NSNumber)?.boolValue ?? false
        self.isDiscarded = (record["isDiscarded"] as? NSNumber)?.boolValue ?? false
        self.tabGroupTitle = enc["tabGroupTitle"] as? String
        self.profileName = enc["profileName"] as? String
    }

    public func toRecord(zoneID: CKRecordZone.ID) -> CKRecord {
        let recordID = CKRecord.ID(recordName: id, zoneID: zoneID)
        let record = CKRecord(recordType: Self.recordType, recordID: recordID)

        return applying(to: record)
    }

    /// Applies the current tab snapshot to a fetched CloudKit record while
    /// retaining its server change tag and other system metadata.
    public func applying(to record: CKRecord) -> CKRecord {
        precondition(record.recordType == Self.recordType)
        precondition(record.recordID.recordName == id)

        record["deviceID"] = deviceID as NSString
        record["browserName"] = browserName as NSString
        record["timestamp"] = timestamp as NSDate
        record["windowIndex"] = windowIndex.map(NSNumber.init(value:))
        record["tabIndex"] = tabIndex.map(NSNumber.init(value:))
        record["tabID"] = tabID.map(NSNumber.init(value:))
        record["isAudible"] = NSNumber(value: isAudible)
        record["isMuted"] = NSNumber(value: isMuted)
        record["isPinned"] = NSNumber(value: isPinned)
        record["isDiscarded"] = NSNumber(value: isDiscarded)

        // End-to-end encrypted fields
        record.encryptedValues["title"] = title as NSString
        record.encryptedValues["url"] = url as NSString
        record.encryptedValues["windowName"] = windowName as NSString?
        record.encryptedValues["tabGroupTitle"] = tabGroupTitle as NSString?
        record.encryptedValues["profileName"] = profileName as NSString?

        return record
    }
}
