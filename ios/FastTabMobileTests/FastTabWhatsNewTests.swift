import XCTest
import IndieWhatsNew
@testable import FastTabMobile

/// FastTab's side of What's New (it replaced the after-browser-close rating popup).
@MainActor
final class FastTabWhatsNewTests: XCTestCase {
    /// The old popup's state key: a Rate tap there still cools the review step down here.
    func testRatingCooldownCarriesOverFromTheOldPopup() {
        XCTAssertEqual(FastTabWhatsNew.storage.ratingStateKey, "ratingPromptState")
        XCTAssertEqual(FastTabWhatsNew.storage.keyPrefix, "fasttab")
    }

    func testAppStoreIDIsFastTabReader() {
        XCTAssertEqual(FastTabWhatsNew.appStoreID, "6828689539")
    }

    /// Notes are looked up by "1.0.0", never "1.0.0 (9)".
    func testTheModelUsesTheMarketingVersion() {
        let version = FastTabWhatsNew.model.appVersion
        XCTAssertFalse(version.contains(" "))
        XCTAssertEqual(version, Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
    }
}
