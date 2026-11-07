import Testing
import CloudKit
import CoreGraphics
import Foundation
import ImageIO
@testable import FastTab
@testable import FastTabSync

/// A solid-colour PNG of the given pixel size, generated in memory.
func makeTestPNG(width: Int, height: Int, noisy: Bool = false) -> Data {
    let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    if noisy {
        var generator = SystemRandomNumberGenerator()
        for y in 0..<height {
            for x in 0..<width {
                ctx.setFillColor(red: .random(in: 0...1, using: &generator),
                                 green: .random(in: 0...1, using: &generator),
                                 blue: .random(in: 0...1, using: &generator), alpha: 1)
                ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
    } else {
        ctx.setFillColor(red: 0.1, green: 0.5, blue: 0.9, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    return out as Data
}

func pixelSize(ofPNG data: Data) -> (Int, Int)? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let w = props[kCGImagePropertyPixelWidth] as? Int,
          let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
    return (w, h)
}

@Suite("SyncedFavicons wire model")
struct SyncedFaviconsTests {
    private let zoneID = CKRecordZone.ID(zoneName: "StateZone", ownerName: CKCurrentUserDefaultName)
    private let sentinelHost = "$(echo INJECTED)"

    private func sample() -> SyncedFavicons {
        SyncedFavicons(
            deviceID: "mac-1",
            icons: ["github.com": Data([1, 2, 3]), "www.example.com": Data([4, 5])],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    @Test("Round-trips through a CloudKit record with the icons encrypted")
    func recordRoundTrip() throws {
        let favicons = sample()
        let record = try #require(favicons.toRecord(zoneID: zoneID))
        #expect(record.recordID.recordName == "mac-1|favicons")
        #expect(record.recordType == "SyncedFavicons")
        #expect(record["iconsData"] == nil)
        #expect(record.encryptedValues["iconsData"] != nil)
        #expect(SyncedFavicons(from: record) == favicons)
    }

    @Test("Applying updates a fetched record in place and refuses a foreign one")
    func applying() throws {
        let record = try #require(sample().toRecord(zoneID: zoneID))
        let newer = SyncedFavicons(deviceID: "mac-1", icons: ["a.com": Data([9])])
        #expect(newer.applying(to: record) === record)
        #expect(SyncedFavicons(from: record)?.icons == ["a.com": Data([9])])

        let other = try #require(SyncedFavicons(deviceID: "mac-2", icons: [:]).toRecord(zoneID: zoneID))
        #expect(sample().applying(to: other) == nil)
    }

    @Test("A garbled payload decodes to nil, not a crash")
    func garbledPayload() throws {
        let record = CKRecord(recordType: SyncedFavicons.recordType,
                              recordID: CKRecord.ID(recordName: "mac-1|favicons", zoneID: zoneID))
        record["deviceID"] = "mac-1" as NSString
        record["updatedAt"] = Date() as NSDate
        record.encryptedValues["iconsData"] = Data("not a plist".utf8) as NSData
        #expect(SyncedFavicons(from: record) == nil)
    }

    @Test("Conflict retry reapplies the icons onto the server record")
    func conflictRetry() throws {
        let intended = try #require(sample().toRecord(zoneID: zoneID))
        let server = CKRecord(recordType: SyncedFavicons.recordType, recordID: intended.recordID)
        let error = CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: server])
        let retry = try #require(SyncService.recordForRetry(intendedRecord: intended, error: error))
        #expect(retry === server)
        #expect(SyncedFavicons(from: retry) == sample())
    }

    // MARK: - Selection / caps

    @Test("Drops empty and oversized icons, dedupes hosts, keeps priority order")
    func selectionDropsAndDedupes() {
        let big = Data(repeating: 7, count: SyncedFavicons.maxIconBytes + 1)
        let ok = Data(repeating: 1, count: 100)
        let picked = SyncedFavicons.select([
            (host: "a.com", png: ok),
            (host: "b.com", png: big),
            (host: "c.com", png: Data()),
            (host: "A.com", png: Data(repeating: 2, count: 10)),   // dup of a.com (case)
            (host: "d.com", png: ok),
        ])
        #expect(Set(picked.keys) == ["a.com", "d.com"])
        #expect(picked["a.com"] == ok)
    }

    @Test("Caps the entry count and total bytes, preferring earlier hosts")
    func selectionCaps() {
        let icon = Data(repeating: 3, count: SyncedFavicons.maxIconBytes)
        let many = (0..<400).map { (host: "h\($0).com", png: icon) }
        let picked = SyncedFavicons.select(many)
        #expect(picked.count <= SyncedFavicons.maxEntries)
        #expect(picked.values.reduce(0) { $0 + $1.count } <= SyncedFavicons.maxTotalBytes)
        #expect(picked["h0.com"] != nil)
        #expect(picked["h399.com"] == nil)
    }

    @Test("A full-size record stays well under CloudKit's 1 MB limit")
    func fullRecordFits() throws {
        let icon = Data(repeating: 3, count: SyncedFavicons.maxIconBytes)
        let picked = SyncedFavicons.select((0..<400).map { (host: "h\($0).com", png: icon) })
        let record = try #require(SyncedFavicons(deviceID: "mac-1", icons: picked).toRecord(zoneID: zoneID))
        let payload = try #require(record.encryptedValues["iconsData"] as? Data)
        #expect(payload.count < 900_000)
    }

    // MARK: - Fingerprint

    @Test("Fingerprint ignores dictionary order and timestamp, changes with content")
    func fingerprint() {
        let a = SyncedFavicons(deviceID: "m", icons: ["x.com": Data([1]), "y.com": Data([2])], updatedAt: .distantPast)
        let b = SyncedFavicons(deviceID: "m", icons: ["y.com": Data([2]), "x.com": Data([1])], updatedAt: Date())
        #expect(a.fingerprint == b.fingerprint)
        let c = SyncedFavicons(deviceID: "m", icons: ["x.com": Data([1]), "y.com": Data([3])])
        #expect(a.fingerprint != c.fingerprint)
        let d = SyncedFavicons(deviceID: "m", icons: ["x.com": Data([1])])
        #expect(a.fingerprint != d.fingerprint)
    }

    // MARK: - Hosts

    @Test("Host extraction: http(s) only, lowercased, junk rejected")
    func hostExtraction() {
        #expect(SyncedFavicons.host(fromURL: "https://GitHub.com/a/b?x=1") == "github.com")
        #expect(SyncedFavicons.host(fromURL: "http://www.Example.com:8080/") == "www.example.com")
        #expect(SyncedFavicons.host(fromURL: "chrome://settings") == nil)
        #expect(SyncedFavicons.host(fromURL: "file:///tmp/x") == nil)
        #expect(SyncedFavicons.host(fromURL: "") == nil)
        #expect(SyncedFavicons.host(fromURL: "not a url") == nil)
    }

    @Test("Lookup tries the exact host, then without www., then with www.")
    func lookupFallback() {
        let favicons = SyncedFavicons(deviceID: "m", icons: [
            "www.exact.com": Data([1]),
            "bare.com": Data([2]),
            "www.wwwonly.com": Data([3]),
        ])
        #expect(favicons.icon(forHost: "www.exact.com") == Data([1]))
        #expect(favicons.icon(forHost: "WWW.EXACT.COM") == Data([1]))
        #expect(favicons.icon(forHost: "www.bare.com") == Data([2]))
        #expect(favicons.icon(forHost: "wwwonly.com") == Data([3]))
        #expect(favicons.icon(forHost: "missing.com") == nil)
        #expect(favicons.icon(forHost: "") == nil)
        #expect(favicons.icon(forHost: sentinelHost) == nil)
    }

    // MARK: - Image encoding

    @Test("Large icons are shrunk to the edge cap; small ones are not enlarged")
    func thumbnailSizes() throws {
        let big = try #require(FaviconImage.compactPNG(from: makeTestPNG(width: 256, height: 256)))
        let bigSize = try #require(pixelSize(ofPNG: big))
        #expect(max(bigSize.0, bigSize.1) <= SyncedFavicons.iconEdgePixels)
        #expect(big.count <= SyncedFavicons.maxIconBytes)

        let tiny = try #require(FaviconImage.compactPNG(from: makeTestPNG(width: 16, height: 16)))
        let tinySize = try #require(pixelSize(ofPNG: tiny))
        #expect(max(tinySize.0, tinySize.1) == 16)
    }

    @Test("An icon that cannot fit the byte cap is dropped; garbage is nil")
    func thumbnailDropsUnfittable() {
        #expect(FaviconImage.compactPNG(from: makeTestPNG(width: 512, height: 512, noisy: true), maxBytes: 200) == nil)
        #expect(FaviconImage.compactPNG(from: Data("nope".utf8)) == nil)
        #expect(FaviconImage.compactPNG(from: Data()) == nil)
    }
}

@Suite("Favicon publish decisions (Mac)")
struct FaviconPublishDecisionTests {
    @Test("One candidate per host, tab order kept, non-web and incognito-free input only")
    func candidates() {
        let out = SyncService.faviconCandidates(from: [
            (browserName: "Chrome", url: "https://github.com/a"),
            (browserName: "Chrome", url: "https://GITHUB.com/b"),
            (browserName: "Safari", url: "chrome://settings"),
            (browserName: "Safari", url: "https://news.ycombinator.com/"),
        ])
        #expect(out.map(\.host) == ["github.com", "news.ycombinator.com"])
        #expect(out.first?.url == "https://github.com/a")
    }

    @Test("A pass runs when the host set changed, or ten minutes passed, never on an identical set")
    func passGate() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(SyncService.shouldRunFaviconPass(signature: "a", lastSignature: nil, lastRunAt: nil, now: now))
        #expect(SyncService.shouldRunFaviconPass(signature: "b", lastSignature: "a", lastRunAt: now, now: now))
        #expect(!SyncService.shouldRunFaviconPass(signature: "a", lastSignature: "a", lastRunAt: now.addingTimeInterval(-60), now: now))
        #expect(SyncService.shouldRunFaviconPass(signature: "a", lastSignature: "a", lastRunAt: now.addingTimeInterval(-601), now: now))
    }

    @Test("Closing a tab keeps its icon; current hosts rank first")
    func retainedOrder() {
        let merged = SyncService.mergedFaviconOrder(
            current: [(host: "new.com", png: Data([1]))],
            retained: ["old.com": Data([2]), "new.com": Data([9])]
        )
        #expect(merged.map(\.host) == ["new.com", "old.com"])
        #expect(merged.first?.png == Data([1]))
    }
}
