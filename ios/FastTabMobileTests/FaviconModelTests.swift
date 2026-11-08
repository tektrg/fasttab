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
}
