import Foundation
import Testing
@testable import FastTabSync

/// Shared bridge rules (Mac command bar + phone): what can be read later, bookmark names,
/// row hints, and when Move to Bookmarks is offered.
@Suite("FastTab List bridges")
struct FastTabListBridgeTests {
    @Test func readLaterOnlyForWebPages() {
        #expect(FastTabListBridge.readLaterLink(url: "https://a.com/x", title: " Hi ")?.title == "Hi")
        #expect(FastTabListBridge.readLaterLink(url: "http://a.com", title: "   ")?.title == nil)
        #expect(FastTabListBridge.readLaterLink(url: "chrome://settings", title: "S") == nil)
        #expect(FastTabListBridge.readLaterLink(url: "not a url", title: nil) == nil)
    }

    @Test func bookmarkTitleFallsBackToWebsiteThenURL() {
        #expect(FastTabListBridge.bookmarkTitle(for: SavedOnIPhoneLink(url: "https://a.com", title: "Named")) == "Named")
        #expect(FastTabListBridge.bookmarkTitle(for: SavedOnIPhoneLink(url: "https://www.a.com/p", title: " ")) == "a.com")
        #expect(FastTabListBridge.bookmarkTitle(for: SavedOnIPhoneLink(url: "nohost", title: nil)) == "nohost")
    }

    @Test func progressHint() {
        #expect(FastTabListBridge.progressHint(for: SavedOnIPhoneLink(url: "https://a.com")) == nil)
        #expect(FastTabListBridge.progressHint(for: SavedOnIPhoneLink(url: "https://a.com", progress: 0.256)) == "26% read")
        #expect(FastTabListBridge.progressHint(for: SavedOnIPhoneLink(url: "https://a.com", readAt: Date(), progress: 0.3)) == "Read")
    }

    @Test func moveToBookmarksNeedsAMac() {
        #expect(FastTabListBridge.offersMoveToBookmarks(isStandalone: false))
        #expect(!FastTabListBridge.offersMoveToBookmarks(isStandalone: true))
    }
}
