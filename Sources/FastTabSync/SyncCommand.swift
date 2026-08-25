import Foundation
import CloudKit

public enum SyncCommandKind: String, Codable, Hashable, Sendable {
    case openOnMac
    case closeTab
    case deleteBookmark
    case deleteHistoryItem
    case moveBookmark
    case addBookmark
}

public enum SyncCommandStatus: String, Codable, Hashable, Sendable {
    case pending
    case inProgress
    case done
    case notFound
    case expired
    case refused
    case needsApproval
}

public struct SyncCommand: Identifiable, Codable, Hashable, Sendable {
    /// How long a command stays actionable after it is issued.
    ///
    /// Deliberately long. A command is an *intent* ("close this tab on my Mac"),
    /// and the target Mac may be asleep, quit, or App-Napped for days before it
    /// ever sees it. The previous 15-minute window silently discarded those
    /// intents, which is indistinguishable from sync being broken. Expiry is a
    /// garbage collector for commands nobody ever acted on — not a delivery
    /// deadline.
    public static let defaultTTL: TimeInterval = 7 * 24 * 60 * 60

    public let id: String
    public let kind: SyncCommandKind
    public let targetDeviceID: String
    public let sourceDeviceName: String
    public let issuedAt: Date
    public let expiresAt: Date
    public let payloadJSON: String
    public var status: SyncCommandStatus
    public var statusReason: String?
    public var completedAt: Date?

    public init(
        id: String = UUID().uuidString,
        kind: SyncCommandKind,
        targetDeviceID: String,
        sourceDeviceName: String,
        issuedAt: Date = Date(),
        expiresAt: Date = Date().addingTimeInterval(SyncCommand.defaultTTL),
        payloadJSON: String,
        status: SyncCommandStatus = .pending,
        statusReason: String? = nil,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.targetDeviceID = targetDeviceID
        self.sourceDeviceName = sourceDeviceName
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.payloadJSON = payloadJSON
        self.status = status
        self.statusReason = statusReason
        self.completedAt = completedAt
    }
}

// Concrete command payloads
public struct OpenOnMacPayload: Codable, Hashable, Sendable {
    public let url: String
    public let title: String?
    public let preferBrowser: String?

    public init(url: String, title: String? = nil, preferBrowser: String? = nil) {
        self.url = url
        self.title = title
        self.preferBrowser = preferBrowser
    }
}

public struct CloseTabPayload: Codable, Hashable, Sendable {
    public let browserName: String
    public let tabID: Int?
    public let url: String
    public let windowIndex: Int?
    public let tabIndex: Int?

    public init(
        browserName: String,
        tabID: Int? = nil,
        url: String,
        windowIndex: Int? = nil,
        tabIndex: Int? = nil
    ) {
        self.browserName = browserName
        self.tabID = tabID
        self.url = url
        self.windowIndex = windowIndex
        self.tabIndex = tabIndex
    }
}

public struct DeleteBookmarkPayload: Codable, Hashable, Sendable {
    public let browserName: String
    public let profileName: String?
    public let bookmarkID: String?
    public let url: String

    public init(browserName: String, profileName: String?, bookmarkID: String?, url: String) {
        self.browserName = browserName
        self.profileName = profileName
        self.bookmarkID = bookmarkID
        self.url = url
    }
}

/// Moves a bookmark to a different folder — same Mac only, optionally a
/// different browser/profile. `destinationFolderPath` is an ordered list of
/// folder display names (matches `SyncedBookmarkItem.folderPath`, split on
/// " / "); an empty array means "top level" (the browser's own catch-all
/// bookmarks folder, e.g. Chromium's "Other Bookmarks").
public struct MoveBookmarkPayload: Codable, Hashable, Sendable {
    public let sourceBrowserName: String
    public let sourceProfileName: String
    public let bookmarkID: String?
    public let url: String
    public let destinationBrowserName: String
    public let destinationProfileName: String
    public let destinationFolderPath: [String]

    public init(
        sourceBrowserName: String,
        sourceProfileName: String,
        bookmarkID: String?,
        url: String,
        destinationBrowserName: String,
        destinationProfileName: String,
        destinationFolderPath: [String]
    ) {
        self.sourceBrowserName = sourceBrowserName
        self.sourceProfileName = sourceProfileName
        self.bookmarkID = bookmarkID
        self.url = url
        self.destinationBrowserName = destinationBrowserName
        self.destinationProfileName = destinationProfileName
        self.destinationFolderPath = destinationFolderPath
    }
}

public struct DeleteHistoryItemPayload: Codable, Hashable, Sendable {
    public let browserName: String
    public let url: String

    public init(browserName: String, url: String) {
        self.browserName = browserName
        self.url = url
    }
}

/// Saves a new bookmark (e.g. from an open tab's URL) into a chosen folder on a
/// Mac. Same shape as the destination half of `MoveBookmarkPayload`, but there
/// is no source node to remove — the tab keeps its open, this only inserts.
public struct AddBookmarkPayload: Codable, Hashable, Sendable {
    public let browserName: String
    public let profileName: String
    public let title: String
    public let url: String
    public let folderPath: [String]

    public init(
        browserName: String,
        profileName: String,
        title: String,
        url: String,
        folderPath: [String]
    ) {
        self.browserName = browserName
        self.profileName = profileName
        self.title = title
        self.url = url
        self.folderPath = folderPath
    }
}

extension SyncCommand {
    public static let recordType = "SyncCommand"

    public init?(from record: CKRecord) {
        guard record.recordType == Self.recordType else { return nil }
        guard let kindRaw = record["kind"] as? String,
              let kind = SyncCommandKind(rawValue: kindRaw),
              let targetDeviceID = record["targetDeviceID"] as? String,
              let sourceDeviceName = record["sourceDeviceName"] as? String,
              let issuedAt = record["issuedAt"] as? Date,
              let expiresAt = record["expiresAt"] as? Date,
              let statusRaw = record["status"] as? String,
              let status = SyncCommandStatus(rawValue: statusRaw) else {
            return nil
        }

        let enc = record.encryptedValues
        guard let payloadJSON = enc["payloadJSON"] as? String else {
            return nil
        }

        self.id = record.recordID.recordName
        self.kind = kind
        self.targetDeviceID = targetDeviceID
        self.sourceDeviceName = sourceDeviceName
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.payloadJSON = payloadJSON
        self.status = status
        self.statusReason = record["statusReason"] as? String
        self.completedAt = record["completedAt"] as? Date
    }

    public func toRecord(zoneID: CKRecordZone.ID) -> CKRecord {
        let recordID = CKRecord.ID(recordName: id, zoneID: zoneID)
        let record = CKRecord(recordType: Self.recordType, recordID: recordID)

        return applying(to: record)
    }

    /// Applies the command's domain values to an existing CloudKit record.
    /// Mutating the fetched record preserves its server change tag and other
    /// system metadata required for a normal optimistic-concurrency update.
    public func applying(to record: CKRecord) -> CKRecord {
        precondition(record.recordType == Self.recordType)
        precondition(record.recordID.recordName == id)

        record["kind"] = kind.rawValue as NSString
        record["targetDeviceID"] = targetDeviceID as NSString
        record["sourceDeviceName"] = sourceDeviceName as NSString
        record["issuedAt"] = issuedAt as NSDate
        record["expiresAt"] = expiresAt as NSDate
        record["status"] = status.rawValue as NSString
        record["statusReason"] = statusReason as NSString?
        record["completedAt"] = completedAt as NSDate?

        // Encrypted payload
        record.encryptedValues["payloadJSON"] = payloadJSON as NSString

        return record
    }
}
