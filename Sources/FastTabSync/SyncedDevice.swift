import Foundation
import CloudKit

/// What kind of app published a `SyncedDevice` record.
///
/// A string wrapper rather than a closed enum so a kind this build has never
/// heard of (a future iPad or second Mac flavour) still decodes — and is
/// treated as "not a Mac", which is the safe reading: the phone must never
/// send commands to something it cannot prove is a Mac.
public struct SyncedDeviceKind: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let mac = SyncedDeviceKind(rawValue: "mac")
    /// The FastTab iOS companion app, whatever hardware it runs on.
    public static let iphone = SyncedDeviceKind(rawValue: "iphone")

    /// Records written before the field existed were all published by Macs —
    /// the phone published no device record at all back then.
    public static let legacyDefault = SyncedDeviceKind.mac

    public init(recordValue: String?) {
        guard let recordValue, !recordValue.isEmpty else {
            self = .legacyDefault
            return
        }
        self.init(rawValue: recordValue)
    }
}

/// Sync command features a device's build understands. Published with the
/// device record so a newer phone can tell an older Mac apart *before*
/// sending a command that Mac would silently drop.
public enum SyncedDeviceCapability {
    /// Understands `SyncCommandKind.deleteBookmarkFolder`.
    public static let deleteBookmarkFolder = "deleteBookmarkFolder"

    /// Everything this build of the Mac app handles.
    public static let currentMac: [String] = [deleteBookmarkFolder]
}

public struct SyncedDevice: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let modelName: String
    public let lastSeenAt: Date
    public let appVersion: String
    public let kind: SyncedDeviceKind
    /// See `SyncedDeviceCapability`. Empty for records from older builds.
    public let capabilities: [String]

    public init(
        id: String,
        name: String,
        modelName: String,
        lastSeenAt: Date = Date(),
        appVersion: String,
        kind: SyncedDeviceKind = .mac,
        capabilities: [String] = []
    ) {
        self.id = id
        self.name = name
        self.modelName = modelName
        self.lastSeenAt = lastSeenAt
        self.appVersion = appVersion
        self.kind = kind
        self.capabilities = capabilities
    }

    public func supports(_ capability: String) -> Bool { capabilities.contains(capability) }

    public var isMac: Bool { kind == .mac }

    private enum CodingKeys: String, CodingKey {
        case id, name, modelName, lastSeenAt, appVersion, kind, capabilities
    }

    /// Hand-written so caches saved before `kind` existed still load: the
    /// synthesised decoder throws on a missing key, which would wipe the
    /// phone's whole cached state on the first launch after an update.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.modelName = try container.decode(String.self, forKey: .modelName)
        self.lastSeenAt = try container.decode(Date.self, forKey: .lastSeenAt)
        self.appVersion = try container.decode(String.self, forKey: .appVersion)
        self.kind = try container.decodeIfPresent(SyncedDeviceKind.self, forKey: .kind) ?? .legacyDefault
        self.capabilities = try container.decodeIfPresent([String].self, forKey: .capabilities) ?? []
    }
}

extension SyncedDevice {
    public static let recordType = "SyncedDevice"

    /// Additive field: old builds ignore it, and a record without it is a Mac.
    static let kindRecordKey = "deviceKind"
    /// Additive field: old builds ignore it; a record without it supports nothing new.
    static let capabilitiesRecordKey = "capabilities"

    /// Every field `init(from:)` reads: the `desiredKeys` a partial fetch
    /// must request to still decode a device.
    public static let recordFieldKeys = ["name", "modelName", "lastSeenAt", "appVersion", kindRecordKey, capabilitiesRecordKey]

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
        self.kind = SyncedDeviceKind(recordValue: record[Self.kindRecordKey] as? String)
        self.capabilities = record[Self.capabilitiesRecordKey] as? [String] ?? []
    }

    public func toRecord(zoneID: CKRecordZone.ID) -> CKRecord {
        let recordID = CKRecord.ID(recordName: id, zoneID: zoneID)
        let record = CKRecord(recordType: Self.recordType, recordID: recordID)
        return applying(to: record)
    }

    public func applying(to record: CKRecord) -> CKRecord {
        precondition(record.recordType == Self.recordType && record.recordID.recordName == id)
        record["name"] = name as NSString
        record["modelName"] = modelName as NSString
        record["lastSeenAt"] = lastSeenAt as NSDate
        record["appVersion"] = appVersion as NSString
        record[Self.kindRecordKey] = kind.rawValue as NSString
        // CloudKit rejects an empty list field, so an empty set is "absent".
        record[Self.capabilitiesRecordKey] = capabilities.isEmpty ? nil : capabilities as NSArray
        return record
    }
}
