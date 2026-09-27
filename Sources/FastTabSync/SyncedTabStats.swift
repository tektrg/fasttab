import Foundation
import CloudKit

/// One calendar day of browser-tab activity on one Mac, in that Mac's time zone.
///
/// Counts only, never URLs or titles. Decoding is tolerant (every field
/// `decodeIfPresent` with a zero default) so an older phone can read a digest
/// written by a newer Mac that added fields, and vice versa.
public struct TabDay: Codable, Hashable, Sendable {
    /// Local calendar day, `yyyy-MM-dd`.
    public var day: String
    public var opened: Int
    public var closed: Int
    /// Time-weighted mean of open tabs while the Mac was awake (sleep gaps are
    /// capped, so asleep time barely counts).
    public var avgOpen: Double
    public var maxOpen: Int
    /// Tabs opened in each local hour 0...23. Always 24 entries.
    public var openedByHour: [Int]

    public static let hoursPerDay = 24

    public init(
        day: String,
        opened: Int = 0,
        closed: Int = 0,
        avgOpen: Double = 0,
        maxOpen: Int = 0,
        openedByHour: [Int] = []
    ) {
        self.day = day
        self.opened = opened
        self.closed = closed
        self.avgOpen = avgOpen
        self.maxOpen = maxOpen
        self.openedByHour = Self.normalizedHours(openedByHour)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            day: try container.decode(String.self, forKey: .day),
            opened: try container.decodeIfPresent(Int.self, forKey: .opened) ?? 0,
            closed: try container.decodeIfPresent(Int.self, forKey: .closed) ?? 0,
            avgOpen: try container.decodeIfPresent(Double.self, forKey: .avgOpen) ?? 0,
            maxOpen: try container.decodeIfPresent(Int.self, forKey: .maxOpen) ?? 0,
            openedByHour: try container.decodeIfPresent([Int].self, forKey: .openedByHour) ?? []
        )
    }

    /// Pads or truncates to exactly 24 hours, so a malformed payload can never
    /// crash an index-by-hour chart.
    private static func normalizedHours(_ hours: [Int]) -> [Int] {
        let clipped = Array(hours.prefix(hoursPerDay))
        return clipped + Array(repeating: 0, count: hoursPerDay - clipped.count)
    }
}

/// One Mac's recent tab-activity digest (last `retainedDayCount` days).
///
/// One record per Mac (`{deviceID}|tabstats`); the phone sums across Macs.
/// The day list lives in `encryptedValues`, like history.
public struct SyncedTabStats: Identifiable, Codable, Hashable, Sendable {
    public static let recordType = "SyncedTabStats"
    public static let retainedDayCount = 90

    public let id: String
    public let deviceID: String
    public let updatedAt: Date
    /// The Mac's time zone the `days` were cut in (e.g. `Asia/Ho_Chi_Minh`).
    public let timeZoneID: String
    public let days: [TabDay]

    public static func recordName(deviceID: String) -> String {
        "\(deviceID)|tabstats"
    }

    public init(deviceID: String, timeZoneID: String, days: [TabDay], updatedAt: Date = Date()) {
        self.id = Self.recordName(deviceID: deviceID)
        self.deviceID = deviceID
        self.updatedAt = updatedAt
        self.timeZoneID = timeZoneID
        self.days = days
    }
}

extension SyncedTabStats {
    private static let daysField = "daysData"

    public init?(from record: CKRecord) {
        guard record.recordType == Self.recordType,
              let deviceID = record["deviceID"] as? String,
              let updatedAt = record["updatedAt"] as? Date,
              let timeZoneID = record["timeZoneID"] as? String,
              let daysData = record.encryptedValues[Self.daysField] as? Data,
              let days = try? JSONDecoder().decode([TabDay].self, from: daysData) else {
            return nil
        }
        self.id = record.recordID.recordName
        self.deviceID = deviceID
        self.updatedAt = updatedAt
        self.timeZoneID = timeZoneID
        self.days = days
    }

    public func toRecord(zoneID: CKRecordZone.ID) -> CKRecord? {
        let recordID = CKRecord.ID(recordName: id, zoneID: zoneID)
        return applying(to: CKRecord(recordType: Self.recordType, recordID: recordID))
    }

    public func applying(to record: CKRecord) -> CKRecord? {
        guard record.recordType == Self.recordType,
              record.recordID.recordName == id,
              let daysData = try? JSONEncoder().encode(days) else { return nil }
        record["deviceID"] = deviceID as NSString
        record["updatedAt"] = updatedAt as NSDate
        record["timeZoneID"] = timeZoneID as NSString
        record.encryptedValues[Self.daysField] = daysData as NSData
        return record
    }
}
