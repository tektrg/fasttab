import XCTest
import UIKit
import FastTabSync
@testable import FastTabMobile

@MainActor
final class FaviconModelTests: XCTestCase {
    private func makeModel() -> FaviconModel {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("favicon-model-\(UUID().uuidString)", isDirectory: true)
        return FaviconModel(store: SyncedFaviconStore(directory: dir))
    }

    private func pngData(color: UIColor) -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16))
        return renderer.pngData { ctx in
            color.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
    }

    func testSyncedIconBecomesImageForTabURL() {
        let model = makeModel()
        XCTAssertNil(model.image(forURL: "https://github.com/a/b"))
        model.apply(SyncedFavicons(deviceID: "mac-1", icons: ["github.com": pngData(color: .red)]))
        XCTAssertNotNil(model.image(forURL: "https://github.com/a/b"))
        XCTAssertNotNil(model.image(forURL: "https://www.github.com/x"))
        XCTAssertNil(model.image(forURL: "https://example.com"))
        XCTAssertNil(model.image(forURL: "chrome://settings"))
    }

    func testUndecodableBytesFallBackToNilInsteadOfCrashing() {
        let model = makeModel()
        model.apply(SyncedFavicons(deviceID: "mac-1", icons: ["bad.com": Data("not an image".utf8)]))
        XCTAssertNil(model.image(forURL: "https://bad.com"))
    }

    func testRevisionBumpsOnlyWhenIconsActuallyChange() {
        let model = makeModel()
        let start = model.revision
        model.remove(recordName: "closed-tab-record")          // typical tab deletion
        XCTAssertEqual(model.revision, start)
        model.apply(SyncedFavicons(deviceID: "mac-1", icons: ["a.com": pngData(color: .blue)]))
        XCTAssertEqual(model.revision, start + 1)
        model.apply(SyncedFavicons(deviceID: "mac-1", icons: ["a.com": pngData(color: .blue)]))
        XCTAssertEqual(model.revision, start + 1)              // identical re-delivery
        model.remove(recordName: SyncedFavicons.recordName(deviceID: "mac-1"))
        XCTAssertEqual(model.revision, start + 2)
        XCTAssertNil(model.image(forURL: "https://a.com"))
    }

    func testHostileHostStringIsInert() {
        let model = makeModel()
        let sentinel = "$(echo injected)" // lowercase: hosts are looked up lowercased
        model.apply(SyncedFavicons(deviceID: "mac-1", icons: [sentinel: pngData(color: .green)]))
        XCTAssertNotNil(model.image(forHost: sentinel))
        XCTAssertNil(model.image(forURL: sentinel))            // not a web URL: never looked up
    }

    /// A PNG header declaring 100000 x 100000 px with no pixel data (decode-bomb shape).
    private func hostileHeaderPNG() -> Data {
        func be(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24 & 255), UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)] }
        func crc32(_ bytes: [UInt8]) -> UInt32 {
            var crc: UInt32 = 0xFFFF_FFFF
            for b in bytes {
                crc ^= UInt32(b)
                for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
            }
            return ~crc
        }
        let body = Array("IHDR".utf8) + be(100_000) + be(100_000) + [8, 6, 0, 0, 0]
        return Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + be(13) + body + be(crc32(body)))
    }

    func testOversizedClaimsAreNeverDecoded() {
        let model = makeModel()
        model.apply(SyncedFavicons(deviceID: "mac-1", icons: ["bomb.com": hostileHeaderPNG()]))
        XCTAssertNil(model.image(forURL: "https://bomb.com"))

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 300))
        let bigPixels = renderer.pngData { ctx in
            UIColor.red.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 300))
        }
        model.apply(SyncedFavicons(deviceID: "mac-2", icons: ["wide.com": bigPixels]))
        XCTAssertNil(model.image(forURL: "https://wide.com"))
    }
}
