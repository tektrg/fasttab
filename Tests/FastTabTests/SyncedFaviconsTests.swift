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

/// A PNG with a valid signature + IHDR declaring the given size and no pixel data:
/// a few dozen bytes that claim an enormous image (decode-bomb shape).
func makeHeaderOnlyPNG(width: UInt32, height: UInt32) -> Data {
    func be(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24 & 255), UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)] }
    func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in bytes {
            crc ^= UInt32(b)
            for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }
    let ihdrBody = Array("IHDR".utf8) + be(width) + be(height) + [8, 6, 0, 0, 0]
    var png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    png += be(13) + ihdrBody + be(crc32(ihdrBody))
    return Data(png)
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

    // MARK: - Decode safety

    @Test("A PNG header declaring gigapixels is refused before any decode (Mac and phone paths)")
    func hostileDeclaredSize() {
        let huge = makeHeaderOnlyPNG(width: 100_000, height: 100_000)
        #expect(FaviconImage.compactPNG(from: huge) == nil)
        #expect(!FaviconImage.isSafeToDecode(huge))
        let mid = makeTestPNG(width: 300, height: 300)
        #expect(!FaviconImage.isSafeToDecode(mid, maxBytes: 1_000_000))   // over the phone's pixel cap
        let ok = makeTestPNG(width: 48, height: 48)
        #expect(FaviconImage.isSafeToDecode(ok))
        #expect(!FaviconImage.isSafeToDecode(ok, maxBytes: 10))           // over the byte cap
        #expect(!FaviconImage.isSafeToDecode(Data()))
        #expect(!FaviconImage.isSafeToDecode(Data("$(echo INJECTED)".utf8)))
    }

    @Test("Oversized source images (over 1024 px) are not decoded on the Mac")
    func oversizedSourceRefused() {
        #expect(FaviconImage.compactPNG(from: makeTestPNG(width: 1100, height: 40)) == nil)
        #expect(FaviconImage.compactPNG(from: makeTestPNG(width: 1024, height: 1024)) != nil)
    }

    @Test("A record entry over the byte cap is dropped at decode time")
    func oversizedEntryDroppedOnDecode() throws {
        let big = Data(repeating: 1, count: SyncedFavicons.maxIconBytes + 1)
        let record = try #require(SyncedFavicons(deviceID: "mac-1", icons: ["a.com": Data([1])]).toRecord(zoneID: zoneID))
        record.encryptedValues["iconsData"] = try SyncedFavicons.encodePayload(["a.com": Data([1]), "big.com": big]) as NSData
        #expect(SyncedFavicons(from: record)?.icons == ["a.com": Data([1])])
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
    @Test("One candidate per host in tab order, keeping every browser that has a tab on it")
    func candidates() {
        let out = SyncService.faviconCandidates(from: [
            (browserName: "Chrome", url: "https://github.com/a"),
            (browserName: "Chrome", url: "https://GITHUB.com/b"),
            (browserName: "Safari", url: "chrome://settings"),
            (browserName: "Safari", url: "https://github.com/c"),
            (browserName: "Safari", url: "https://news.ycombinator.com/"),
        ])
        #expect(out.map(\.host) == ["github.com", "news.ycombinator.com"])
        #expect(out[0].sources == [
            FaviconSource(browserName: "Chrome", url: "https://github.com/a"),
            FaviconSource(browserName: "Safari", url: "https://github.com/c"),
        ])
        #expect(out[1].sources.count == 1)
    }

    @Test("Lookup rounds try the next browser only for hosts still unresolved")
    func lookupRounds() {
        let candidates = SyncService.faviconCandidates(from: [
            (browserName: "Chrome", url: "https://a.com/1"),
            (browserName: "Safari", url: "https://a.com/2"),
            (browserName: "Chrome", url: "https://b.com/1"),
        ])
        let round0 = SyncService.faviconLookups(for: candidates, round: 0, resolved: [])
        #expect(round0.map(\.host) == ["a.com", "b.com"])
        #expect(round0.map(\.source.browserName) == ["Chrome", "Chrome"])
        let round1 = SyncService.faviconLookups(for: candidates, round: 1, resolved: ["b.com"])
        #expect(round1.map(\.host) == ["a.com"])
        #expect(round1.first?.source.browserName == "Safari")
        #expect(SyncService.faviconLookups(for: candidates, round: 1, resolved: ["a.com"]).isEmpty)
        #expect(SyncService.faviconLookups(for: candidates, round: 2, resolved: []).isEmpty)
    }

    @Test("A failed host is skipped for an hour unless its browsers changed")
    func failureBackoff() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let failure = FaviconLookupFailure(at: now.addingTimeInterval(-600), browsers: ["Chrome"])
        #expect(SyncService.shouldSkipFailedFavicon(failure, currentBrowsers: ["Chrome"], now: now))
        #expect(!SyncService.shouldSkipFailedFavicon(failure, currentBrowsers: ["Chrome", "Safari"], now: now))
        let old = FaviconLookupFailure(at: now.addingTimeInterval(-3601), browsers: ["Chrome"])
        #expect(!SyncService.shouldSkipFailedFavicon(old, currentBrowsers: ["Chrome"], now: now))
        #expect(!SyncService.shouldSkipFailedFavicon(nil, currentBrowsers: ["Chrome"], now: now))
    }

    @Test("Passes start at least 30 s apart, with a 3 s debounce otherwise")
    func passSpacing() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(SyncService.faviconPassDelay(lastPassStartedAt: nil, now: now) == 3)
        #expect(SyncService.faviconPassDelay(lastPassStartedAt: now.addingTimeInterval(-5), now: now) == 25)
        #expect(SyncService.faviconPassDelay(lastPassStartedAt: now.addingTimeInterval(-29), now: now) == 3)
        #expect(SyncService.faviconPassDelay(lastPassStartedAt: now.addingTimeInterval(-300), now: now) == 3)
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
