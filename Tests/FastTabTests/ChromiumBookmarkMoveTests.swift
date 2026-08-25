import Foundation
import Testing
@testable import FastTab

/// Exercises `ChromiumBackend.removeBookmarkForMove`/`insertBookmark` against a
/// real on-disk `Bookmarks` JSON file laid out like Chromium's own — these are
/// brand-new file-mutation primitives (nothing like them existed before the
/// move-bookmark feature) with no prior coverage to lean on.
struct ChromiumBookmarkMoveTests {
    private static let sampleBookmarksJSON = """
    {
      "checksum": "placeholder",
      "roots": {
        "bookmark_bar": {
          "children": [
            {
              "children": [
                { "date_added": "13300000000000000", "id": "5", "name": "Move Me", "type": "url", "url": "https://example.com/moveme" },
                { "date_added": "13300000000000000", "id": "6", "name": "Stay Put", "type": "url", "url": "https://example.com/stayput" }
              ],
              "date_added": "13300000000000000", "id": "4", "name": "Work", "type": "folder"
            }
          ],
          "date_added": "13300000000000000", "id": "1", "name": "Bookmark Bar", "type": "folder"
        },
        "other": {
          "children": [],
          "date_added": "13300000000000000", "id": "2", "name": "Other Bookmarks", "type": "folder"
        },
        "synced": {
          "children": [],
          "date_added": "13300000000000000", "id": "3", "name": "Mobile Bookmarks", "type": "folder"
        }
      },
      "version": 1
    }
    """

    private func makeProfile(named name: String, in baseDir: URL, json: String = sampleBookmarksJSON) throws -> URL {
        let profileDir = baseDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)
        try json.write(to: profileDir.appendingPathComponent("Bookmarks"), atomically: true, encoding: .utf8)
        return profileDir
    }

    private func makeBackend(supportDirectory: URL) -> ChromiumBackend {
        ChromiumBackend(appName: "Google Chrome", bundleIdentifier: "com.google.Chrome", supportDirectory: supportDirectory.path)
    }

    @Test func removeBookmarkForMoveExtractsNodeAndFolderTrailLeavingSiblingIntact() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let profileDir = try makeProfile(named: "Default", in: base)
        let backend = makeBackend(supportDirectory: base)

        let result = BrowserSearchResult(
            title: "Move Me", url: "https://example.com/moveme", browserName: "Google Chrome",
            type: .bookmark, timestamp: Date(), bookmarkID: "5", profileName: "Default"
        )
        let removed = try #require(backend.removeBookmarkForMove(result))

        #expect(removed.title == "Move Me")
        #expect(removed.url == "https://example.com/moveme")
        #expect(removed.originalFolderPath == ["Bookmark Bar", "Work"])

        let data = try Data(contentsOf: profileDir.appendingPathComponent("Bookmarks"))
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let roots = root?["roots"] as? [String: Any]
        let bar = roots?["bookmark_bar"] as? [String: Any]
        let workFolder = (bar?["children"] as? [[String: Any]])?.first { ($0["id"] as? String) == "4" }
        let workChildren = workFolder?["children"] as? [[String: Any]]

        #expect(workChildren?.contains { ($0["id"] as? String) == "5" } == false)
        #expect(workChildren?.contains { ($0["id"] as? String) == "6" } == true)
    }

    @Test func removeBookmarkForMoveReturnsNilWhenIDNotFound() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        _ = try makeProfile(named: "Default", in: base)
        let backend = makeBackend(supportDirectory: base)

        let result = BrowserSearchResult(
            title: "Ghost", url: "https://example.com/ghost", browserName: "Google Chrome",
            type: .bookmark, timestamp: Date(), bookmarkID: "999", profileName: "Default"
        )
        #expect(backend.removeBookmarkForMove(result) == nil)
    }

    @Test func insertBookmarkAtTopLevelLandsInOtherRoot() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let profileDir = try makeProfile(named: "Default", in: base)
        let backend = makeBackend(supportDirectory: base)

        let inserted = backend.insertBookmark(
            title: "New Top Level", url: "https://example.com/new", dateAdded: Date(),
            profileName: "Default", folderPath: []
        )
        #expect(inserted)

        let data = try Data(contentsOf: profileDir.appendingPathComponent("Bookmarks"))
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let roots = root?["roots"] as? [String: Any]
        let other = roots?["other"] as? [String: Any]
        let otherChildren = other?["children"] as? [[String: Any]]

        let newNode = otherChildren?.first { ($0["url"] as? String) == "https://example.com/new" }
        #expect(newNode?["name"] as? String == "New Top Level")
        // Highest existing id in the fixture is 6 — the new node must not collide.
        #expect(newNode?["id"] as? String == "7")
    }

    @Test func insertBookmarkAtNamedFolderPathDescendsCorrectly() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let profileDir = try makeProfile(named: "Default", in: base)
        let backend = makeBackend(supportDirectory: base)

        let inserted = backend.insertBookmark(
            title: "Moved In", url: "https://example.com/movedin", dateAdded: nil,
            profileName: "Default", folderPath: ["Bookmark Bar", "Work"]
        )
        #expect(inserted)

        let data = try Data(contentsOf: profileDir.appendingPathComponent("Bookmarks"))
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let roots = root?["roots"] as? [String: Any]
        let bar = roots?["bookmark_bar"] as? [String: Any]
        let workFolder = (bar?["children"] as? [[String: Any]])?.first { ($0["id"] as? String) == "4" }
        let workChildren = workFolder?["children"] as? [[String: Any]]

        #expect(workChildren?.contains { ($0["url"] as? String) == "https://example.com/movedin" } == true)
        // The two bookmarks already in Work must survive untouched.
        #expect(workChildren?.count == 3)
    }

    @Test func insertBookmarkCreatesMissingFolderTrail() throws {
        // Whole-folder moves insert into a destination path whose own folder
        // doesn't exist yet ("Work" moved into "Archive" writes into
        // "Archive/Work"), so a missing segment must be created, not failed on.
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let profileDir = try makeProfile(named: "Default", in: base)
        let backend = makeBackend(supportDirectory: base)

        let inserted = backend.insertBookmark(
            title: "Nowhere", url: "https://example.com/nowhere", dateAdded: nil,
            profileName: "Default", folderPath: ["Bookmark Bar", "Does Not Exist"]
        )
        #expect(inserted)

        let data = try Data(contentsOf: profileDir.appendingPathComponent("Bookmarks"))
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let roots = root?["roots"] as? [String: Any]
        let bar = roots?["bookmark_bar"] as? [String: Any]
        let createdFolder = (bar?["children"] as? [[String: Any]])?.first { ($0["name"] as? String) == "Does Not Exist" }
        #expect(createdFolder?["type"] as? String == "folder")
        #expect((createdFolder?["children"] as? [[String: Any]])?.contains { ($0["url"] as? String) == "https://example.com/nowhere" } == true)
    }

    @Test func insertBookmarkCreatesDeepFolderChainAtDestination() throws {
        // The folder-move scenario: leaves under "Work/Projects" land at
        // "Archive/Work/Projects", so an intermediate "Projects" folder that
        // doesn't exist at the destination must be created.
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let profileDir = try makeProfile(named: "Default", in: base)
        let backend = makeBackend(supportDirectory: base)

        let inserted = backend.insertBookmark(
            title: "Nested", url: "https://example.com/nested", dateAdded: nil,
            profileName: "Default", folderPath: ["Bookmark Bar", "Work", "Projects"]
        )
        #expect(inserted)

        let data = try Data(contentsOf: profileDir.appendingPathComponent("Bookmarks"))
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let roots = root?["roots"] as? [String: Any]
        let bar = roots?["bookmark_bar"] as? [String: Any]
        let workFolder = (bar?["children"] as? [[String: Any]])?.first { ($0["id"] as? String) == "4" }
        let projectsFolder = (workFolder?["children"] as? [[String: Any]])?.first { ($0["name"] as? String) == "Projects" }
        #expect(projectsFolder?["type"] as? String == "folder")
        // The two bookmarks already in Work must survive untouched.
        #expect((workFolder?["children"] as? [[String: Any]])?.count == 3)
        #expect((projectsFolder?["children"] as? [[String: Any]])?.contains { ($0["url"] as? String) == "https://example.com/nested" } == true)
    }

    @Test func insertBookmarkCreatesTopLevelFolderUnderOtherRoot() throws {
        // Moving a folder to top level: its first path segment matches no root,
        // so the folder chain is created under Chromium's catch-all "other" root
        // — the same place an empty (top-level) destination lands.
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let profileDir = try makeProfile(named: "Default", in: base)
        let backend = makeBackend(supportDirectory: base)

        let inserted = backend.insertBookmark(
            title: "Top Move", url: "https://example.com/top", dateAdded: nil,
            profileName: "Default", folderPath: ["Fresh Folder"]
        )
        #expect(inserted)

        let data = try Data(contentsOf: profileDir.appendingPathComponent("Bookmarks"))
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let roots = root?["roots"] as? [String: Any]
        let other = roots?["other"] as? [String: Any]
        let createdFolder = (other?["children"] as? [[String: Any]])?.first { ($0["name"] as? String) == "Fresh Folder" }
        #expect(createdFolder?["type"] as? String == "folder")
        #expect((createdFolder?["children"] as? [[String: Any]])?.contains { ($0["url"] as? String) == "https://example.com/top" } == true)
    }

    /// The end-to-end scenario `handleMoveBookmarkCommand` performs when the
    /// destination succeeds: remove from one profile, insert into another,
    /// same backend (mirrors a same-browser, cross-profile move).
    @Test func removeThenInsertMovesBookmarkAcrossProfiles() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let sourceDir = try makeProfile(named: "Default", in: base)
        let destDir = try makeProfile(named: "Work", in: base)
        let backend = makeBackend(supportDirectory: base)

        let sourceResult = BrowserSearchResult(
            title: "Move Me", url: "https://example.com/moveme", browserName: "Google Chrome",
            type: .bookmark, timestamp: Date(), bookmarkID: "5", profileName: "Default"
        )
        let removed = try #require(backend.removeBookmarkForMove(sourceResult))
        let inserted = backend.insertBookmark(
            title: removed.title, url: removed.url, dateAdded: removed.dateAdded,
            profileName: "Work", folderPath: []
        )
        #expect(inserted)

        let sourceData = try Data(contentsOf: sourceDir.appendingPathComponent("Bookmarks"))
        let destData = try Data(contentsOf: destDir.appendingPathComponent("Bookmarks"))
        #expect(String(data: sourceData, encoding: .utf8)?.contains("Move Me") == false)
        #expect(String(data: destData, encoding: .utf8)?.contains("Move Me") == true)
    }
}
