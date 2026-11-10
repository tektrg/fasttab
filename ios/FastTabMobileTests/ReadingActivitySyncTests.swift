import FastTabSync
import XCTest
@testable import FastTabMobile

/// The phone's side of reading-activity sync: which progress entries go to the Mac.
final class ReadingActivitySyncTests: XCTestCase {
    func testEveryStartedPageBecomesAnActivityNewestFirst() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let activities = ReaderReadingProgress.activities(from: [
            "https://a.com/read": (1.0, t0, "Read one"),
            "https://b.com/half": (0.5, t0.addingTimeInterval(60), nil),
            "https://c.com/unstarted": (0.0, t0.addingTimeInterval(120), "Never scrolled"),
        ])
        XCTAssertEqual(activities.map(\.url), ["https://b.com/half", "https://a.com/read"])
        XCTAssertEqual(activities.last?.title, "Read one")
        XCTAssertEqual(activities.first?.id, FastTabListLibrary.itemID(for: "https://b.com/half"))
    }

    @MainActor
    func testSettingProgressPostsALocalChangeOnlyWhenItMoves() {
        let url = URL(string: "https://example.com/activity-\(UUID().uuidString)")!
        let store = ReaderReadingProgress.shared
        var posts = 0
        let token = NotificationCenter.default.addObserver(
            forName: .readingActivityDidChangeLocally, object: nil, queue: nil) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        store.set(progress: 0.3, for: url, title: "T")
        store.set(progress: 0.3, for: url, title: "T")
        store.set(progress: 0.6, for: url)
        XCTAssertEqual(posts, 2)
        let synced = store.readingActivitiesForSync().first { $0.url == url.readerCanonicalKey }
        XCTAssertEqual(synced?.title, "T", "a later save without a title keeps the known one")
        XCTAssertEqual(synced?.progress ?? 0, 0.6, accuracy: 0.001)
    }
}
