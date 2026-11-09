import Foundation
import CloudKit
import CryptoKit

/// One Mac's site icons, keyed by host (`github.com`), so the phone's tab list
/// can show favicons instead of a generic globe.
///
/// One record per Mac (`{deviceID}|favicons`). The icons travel in
/// `encryptedValues` like titles and URLs, so nothing about which sites are open
/// leaves the user's iCloud, and the phone never contacts a site to fetch one.
/// The payload is a binary property list (`[host: PNG bytes]`), not JSON, to avoid
/// base64 inflation against CloudKit's 1 MB record limit.
public struct SyncedFavicons: Identifiable, Hashable, Sendable {
    public static let recordType = "SyncedFavicons"

    /// Hosts per record. Open tabs rarely span more distinct sites than this.
    public static let maxEntries = 150
    /// Largest accepted PNG. A 48 px favicon is normally 0.5–4 KB; anything
    /// bigger is a photo-like icon not worth the sync bytes. (Generous enough that a
    /// 48 px icon isn't pushed down to a blurry 24 px one.)
    public static let maxIconBytes = 8 * 1024
    /// Whole-record budget for the icon bytes (the 1 MB CloudKit limit minus
    /// plist overhead and headroom).
    public static let maxTotalBytes = 600 * 1024
    /// Longest edge, in pixels, of a published icon (2x of a 16–20 pt row, at 3x it
    /// is still crisp enough for a 20 pt icon).
    public static let iconEdgePixels = 48
    /// Refuse to build a record whose payload would exceed this.
    static let maxPayloadBytes = 900_000

    public let id: String
    public let deviceID: String
    public let updatedAt: Date
    /// Lowercased host → PNG data.
    public let icons: [String: Data]

    public static func recordName(deviceID: String) -> String {
        "\(deviceID)|favicons"
    }

    public init(deviceID: String, icons: [String: Data], updatedAt: Date = Date()) {
        self.id = Self.recordName(deviceID: deviceID)
        self.deviceID = deviceID
        self.updatedAt = updatedAt
        self.icons = icons
    }
}

// MARK: - Hosts, selection, fingerprint

extension SyncedFavicons {
    /// Lowercased host of an http(s) URL, or nil for anything else.
    public static func host(fromURL string: String) -> String? {
        guard let url = URL(string: string),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host(percentEncoded: false)?.lowercased(),
              !host.isEmpty else { return nil }
        return host
    }

    /// Picks what fits the record: drops empty/oversized icons and repeated
    /// hosts, then keeps hosts in the given (priority) order until the entry or
    /// byte budget is spent.
    public static func select(_ ordered: [(host: String, png: Data)]) -> [String: Data] {
        var out: [String: Data] = [:]
        var total = 0
        for (rawHost, png) in ordered {
            let host = rawHost.lowercased()
            guard !host.isEmpty, out[host] == nil,
                  !png.isEmpty, png.count <= maxIconBytes else { continue }
            guard out.count < maxEntries, total + png.count <= maxTotalBytes else { continue }
            out[host] = png
            total += png.count
        }
        return out
    }

    /// The icon for `host`: exact match, else the same host without a leading
    /// `www.`, else with one (sites are keyed by whatever host the Mac's tab had).
    public func icon(forHost host: String) -> Data? {
        let key = host.lowercased()
        guard !key.isEmpty else { return nil }
        if let exact = icons[key] { return exact }
        if key.hasPrefix("www.") {
            return icons[String(key.dropFirst(4))]
        }
        return icons["www." + key]
    }

    /// Stable content hash (host + icon bytes only: not the timestamp or the
    /// dictionary's iteration order) used to skip re-uploading an unchanged set.
    public var fingerprint: String {
        var hasher = SHA256()
        for host in icons.keys.sorted() {
            hasher.update(data: Data(host.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: Data(SHA256.hash(data: icons[host] ?? Data())))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - CloudKit

extension SyncedFavicons {
    private static let iconsField = "iconsData"

    public init?(from record: CKRecord) {
        guard record.recordType == Self.recordType,
              let deviceID = record["deviceID"] as? String,
              let updatedAt = record["updatedAt"] as? Date,
              let payload = record.encryptedValues[Self.iconsField] as? Data,
              let icons = try? PropertyListDecoder().decode([String: Data].self, from: payload) else {
            return nil
        }
        self.id = record.recordID.recordName
        self.deviceID = deviceID
        self.updatedAt = updatedAt
        // Entries over the byte cap were never ours to publish: drop them rather than decode.
        self.icons = icons.filter { $0.value.count <= Self.maxIconBytes }
    }

    public func toRecord(zoneID: CKRecordZone.ID) -> CKRecord? {
        let recordID = CKRecord.ID(recordName: id, zoneID: zoneID)
        return applying(to: CKRecord(recordType: Self.recordType, recordID: recordID))
    }

    public func applying(to record: CKRecord) -> CKRecord? {
        guard record.recordType == Self.recordType,
              record.recordID.recordName == id,
              let payload = try? Self.encodePayload(icons),
              payload.count <= Self.maxPayloadBytes else { return nil }
        record["deviceID"] = deviceID as NSString
        record["updatedAt"] = updatedAt as NSDate
        record.encryptedValues[Self.iconsField] = payload as NSData
        return record
    }

    static func encodePayload(_ icons: [String: Data]) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(icons)
    }
}
