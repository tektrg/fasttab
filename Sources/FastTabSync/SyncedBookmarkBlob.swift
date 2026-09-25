import Foundation
import CloudKit
import CryptoKit

public struct SyncedBookmarkItem: Codable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let url: String
    public let folderPath: String?
    public let dateAdded: Date?

    public init(
        id: String,
        title: String,
        url: String,
        folderPath: String? = nil,
        dateAdded: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.folderPath = folderPath
        self.dateAdded = dateAdded
    }
}

public struct SyncedBookmarkBlob: Identifiable, Codable, Hashable, Sendable {
    public let id: String // e.g. "device_chrome_Default"
    public let deviceID: String
    public let browserName: String
    public let profileName: String
    public let contentHash: String
    public let updatedAt: Date
    public let bookmarks: [SyncedBookmarkItem]

    public init(
        deviceID: String,
        browserName: String,
        profileName: String,
        bookmarks: [SyncedBookmarkItem],
        updatedAt: Date = Date()
    ) {
        self.id = "\(deviceID)|\(browserName)|\(profileName)"
        self.deviceID = deviceID
        self.browserName = browserName
        self.profileName = profileName
        self.updatedAt = updatedAt
        self.bookmarks = bookmarks

        // Calculate SHA256 of encoded bookmark array
        let data = (try? JSONEncoder().encode(bookmarks)) ?? Data()
        let digest = SHA256.hash(data: data)
        self.contentHash = digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    public init(
        id: String,
        deviceID: String,
        browserName: String,
        profileName: String,
        contentHash: String,
        updatedAt: Date,
        bookmarks: [SyncedBookmarkItem]
    ) {
        self.id = id
        self.deviceID = deviceID
        self.browserName = browserName
        self.profileName = profileName
        self.contentHash = contentHash
        self.updatedAt = updatedAt
        self.bookmarks = bookmarks
    }
}

extension SyncedBookmarkBlob {
    public static let recordType = "SyncedBookmarkBlob"

    public init?(from record: CKRecord) {
        guard record.recordType == Self.recordType else { return nil }
        guard let deviceID = record["deviceID"] as? String,
              let browserName = record["browserName"] as? String,
              let profileName = record["profileName"] as? String,
              let contentHash = record["contentHash"] as? String,
              let updatedAt = record["updatedAt"] as? Date else {
            return nil
        }

        // Encrypted bookmarks payload
        guard let encryptedData = record.encryptedValues["bookmarksData"] as? Data,
              let bookmarks = try? JSONDecoder().decode([SyncedBookmarkItem].self, from: encryptedData) else {
            return nil
        }

        self.id = record.recordID.recordName
        self.deviceID = deviceID
        self.browserName = browserName
        self.profileName = profileName
        self.contentHash = contentHash
        self.updatedAt = updatedAt
        self.bookmarks = bookmarks
    }

    public func toRecord(zoneID: CKRecordZone.ID) -> CKRecord? {
        guard let data = try? JSONEncoder().encode(bookmarks) else { return nil }

        let recordID = CKRecord.ID(recordName: id, zoneID: zoneID)
        let record = CKRecord(recordType: Self.recordType, recordID: recordID)

        record["deviceID"] = deviceID as NSString
        record["browserName"] = browserName as NSString
        record["profileName"] = profileName as NSString
        record["contentHash"] = contentHash as NSString
        record["updatedAt"] = updatedAt as NSDate

        // Encrypted data payload
        record.encryptedValues["bookmarksData"] = data as NSData

        return record
    }
}
