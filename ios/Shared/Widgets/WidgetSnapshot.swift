import Foundation
import FastTabSync

/// Everything the home-screen widgets show, written by the app as one JSON file in the app-group
/// container and read by `FastTabWidgets`. Compiled into both targets (ios/Shared/Widgets).
///
/// The widget never computes feeds itself: it has no network, no sync engine and a tight memory
/// budget. The app decides what each widget shows (`WidgetSnapshotBuilder`) and the widget only
/// lays it out, except for date-relative values (today's ring) which it re-derives at render time
/// so the ring empties at midnight without the app running.
struct WidgetSnapshot: Codable, Equatable {
    struct Link: Codable, Equatable, Identifiable {
        var id: String { url.absoluteString }
        let title: String
        let url: URL
        /// Lowercased host without `www.`, the small caption and monogram under the title.
        let domain: String
    }

    struct Reading: Codable, Equatable {
        /// Words the ring is closed at.
        let dailyWordGoal: Int
        /// Words read per day, keyed by the day's start (in the phone's time zone). Days with no
        /// reading are absent. Long enough to cover any realistic streak.
        let wordsByDay: [Date: Double]
    }

    struct Shuffle: Codable, Equatable {
        let item: Link
        /// Where the card came from ("Bookmark", "Open tab · Chrome", a folder path).
        let badge: String
        /// Set for a highlight card so the reader scrolls to it.
        let highlightID: String?
        /// Thumbnail in the app-group container, present once the app has downloaded it.
        /// Named per item so a stale image never shows under a new card.
        let thumbnailFileName: String?
    }

    struct OpenTabs: Codable, Equatable {
        let totalCount: Int
        /// Most recently active first, at most `WidgetSnapshotBuilder.recentTabLimit`.
        let recent: [Link]
    }

    var upNext: [Link] = []
    var reading: Reading?
    var shuffle: Shuffle?
    var openTabs: OpenTabs?
    var writtenAt: Date = .distantPast

    static let empty = WidgetSnapshot()
}

/// Reads and writes `WidgetSnapshot` and its thumbnails in the shared app-group container.
enum WidgetSnapshotStore {
    static let fileName = "widget_snapshot.json"
    static let thumbnailDirectoryName = "widget_thumbnails"

    static var directoryURL: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SyncConstants.appGroupIdentifier)
            ?? FileManager.default.temporaryDirectory
    }

    static var snapshotURL: URL { directoryURL.appendingPathComponent(fileName) }
    static var thumbnailDirectoryURL: URL { directoryURL.appendingPathComponent(thumbnailDirectoryName, isDirectory: true) }

    static func thumbnailURL(named fileName: String) -> URL {
        thumbnailDirectoryURL.appendingPathComponent(fileName)
    }

    static func load(from url: URL = snapshotURL) -> WidgetSnapshot {
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? decoder.decode(WidgetSnapshot.self, from: data) else { return .empty }
        return snapshot
    }

    static func save(_ snapshot: WidgetSnapshot, to url: URL = snapshotURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(snapshot).write(to: url, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}
