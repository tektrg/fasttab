import CloudKit
import FastTabSync
import Foundation
import Testing
@testable import FastTab

/// Whole-folder delete: the Chromium file edit, the extension-first decorator,
/// the sync wire format and the copy both apps show. Every write goes to a
/// temp-dir fixture — never a real browser profile.
@Suite struct BookmarkFolderDeleteTests {
    /// Bar(1) > Work(4) > [a(5), Projects(7) > [b(8), Deep(9) > [c(10)]]], Bar > Keep(11) > [d(12)]
    /// Other(2) > Work(13) > [e(14)]  — a second "Work", under a different root.
    static let fixtureJSON = """
    {
      "checksum": "placeholder",
      "roots": {
        "bookmark_bar": {
          "children": [
            { "children": [
                { "id": "5", "name": "a", "type": "url", "url": "https://example.com/a" },
                { "children": [
                    { "id": "8", "name": "b", "type": "url", "url": "https://example.com/b" },
                    { "children": [ { "id": "10", "name": "c", "type": "url", "url": "https://example.com/c" } ],
                      "id": "9", "name": "Deep", "type": "folder" }
                  ], "id": "7", "name": "Projects", "type": "folder" }
              ], "id": "4", "name": "Work", "type": "folder" },
            { "children": [ { "id": "12", "name": "d", "type": "url", "url": "https://example.com/d" } ],
              "id": "11", "name": "Keep", "type": "folder" }
          ],
          "id": "1", "name": "Bookmarks Bar", "type": "folder"
        },
        "other": {
          "children": [
            { "children": [ { "id": "14", "name": "e", "type": "url", "url": "https://example.com/e" } ],
              "id": "13", "name": "Work", "type": "folder" }
          ],
          "id": "2", "name": "Other Bookmarks", "type": "folder"
        },
        "synced": { "children": [], "id": "3", "name": "Mobile Bookmarks", "type": "folder" }
      },
      "version": 1
    }
    """

    private final class Fixture {
        let base: URL
        let bookmarksURL: URL
        let backend: ChromiumBackend

        init(json: String = BookmarkFolderDeleteTests.fixtureJSON) throws {
            base = FileManager.default.temporaryDirectory.appendingPathComponent("bmfolder-\(UUID().uuidString)")
            let profileDir = base.appendingPathComponent("Default", isDirectory: true)
            try FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)
            bookmarksURL = profileDir.appendingPathComponent("Bookmarks")
            try json.write(to: bookmarksURL, atomically: true, encoding: .utf8)
            backend = ChromiumBackend(appName: "Google Chrome", bundleIdentifier: "com.google.Chrome", supportDirectory: base.path)
        }

        deinit { try? FileManager.default.removeItem(at: base) }

        func raw() throws -> String { try String(contentsOf: bookmarksURL, encoding: .utf8) }

        func allIDs() throws -> Set<String> {
            let data = try Data(contentsOf: bookmarksURL)
            let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            var ids: Set<String> = []
            func visit(_ node: [String: Any]) {
                if let id = node["id"] as? String { ids.insert(id) }
                for child in (node["children"] as? [[String: Any]]) ?? [] { visit(child) }
            }
            for value in (root["roots"] as? [String: Any] ?? [:]).values {
                if let node = value as? [String: Any] { visit(node) }
            }
            return ids
        }
    }

    private func target(_ locator: BookmarkFolderLocator) -> BookmarkFolderTarget {
        BookmarkFolderTarget(profileName: "Default", locator: locator)
    }

    // MARK: - Chromium file fallback

    @Test func deleteByIDRemovesWholeSubtreeAndKeepsSiblings() throws {
        let f = try Fixture()
        let outcome = f.backend.deleteBookmarkFolder(target(.id("4")))
        #expect(outcome == .deleted(bookmarkCount: 3, subfolderCount: 2))
        let ids = try f.allIDs()
        for gone in ["4", "5", "7", "8", "9", "10"] { #expect(!ids.contains(gone)) }
        for kept in ["1", "2", "3", "11", "12", "13", "14"] { #expect(ids.contains(kept)) }
    }

    @Test func deleteByPathRemovesOnlyTheFolderUnderThatRoot() throws {
        let f = try Fixture()
        let outcome = f.backend.deleteBookmarkFolder(target(.path(["Other Bookmarks", "Work"])))
        #expect(outcome == .deleted(bookmarkCount: 1, subfolderCount: 0))
        let ids = try f.allIDs()
        #expect(!ids.contains("13") && !ids.contains("14"))
        #expect(ids.contains("4") && ids.contains("10"))
    }

    @Test func nestedPathDeletesOnlyTheInnerFolder() throws {
        let f = try Fixture()
        #expect(f.backend.deleteBookmarkFolder(target(.path(["Bookmarks Bar", "Work", "Projects"]))) == .deleted(bookmarkCount: 2, subfolderCount: 1))
        let ids = try f.allIDs()
        #expect(ids.contains("4") && ids.contains("5"))
        #expect(!ids.contains("7") && !ids.contains("10"))
    }

    @Test func rootFoldersAreNeverDeleted() throws {
        let f = try Fixture()
        let before = try f.raw()
        for id in ["1", "2", "3"] {
            #expect(f.backend.deleteBookmarkFolder(target(.id(id))) == .rootFolder)
        }
        #expect(f.backend.deleteBookmarkFolder(target(.path(["Bookmarks Bar"]))) == .rootFolder)
        #expect(f.backend.deleteBookmarkFolder(target(.path(["Mobile Bookmarks"]))) == .rootFolder)
        #expect(try f.raw() == before)
    }

    @Test func bookmarkIDOrMissingFolderIsNotFoundAndFileUntouched() throws {
        let f = try Fixture()
        let before = try f.raw()
        #expect(f.backend.deleteBookmarkFolder(target(.id("5"))) == .notFound)
        #expect(f.backend.deleteBookmarkFolder(target(.id("999"))) == .notFound)
        #expect(f.backend.deleteBookmarkFolder(target(.path(["Bookmarks Bar", "Nope"]))) == .notFound)
        #expect(f.backend.deleteBookmarkFolder(target(.path([]))) == .notFound)
        #expect(f.backend.deleteBookmarkFolder(BookmarkFolderTarget(profileName: "Profile 9", locator: .id("4"))) == .notFound)
        #expect(try f.raw() == before)
    }

    @Test func ambiguousPathIsRefusedAndFileUntouched() throws {
        let json = Self.fixtureJSON.replacingOccurrences(of: "\"name\": \"Keep\"", with: "\"name\": \"Work\"")
        let f = try Fixture(json: json)
        let before = try f.raw()
        #expect(f.backend.deleteBookmarkFolder(target(.path(["Bookmarks Bar", "Work"]))) == .ambiguous)
        #expect(try f.raw() == before)
    }

    @Test func hostileFolderNameIsMatchedLiterallyNeverEvaluated() throws {
        let hostile = "$(echo INJECTED)"
        let json = Self.fixtureJSON.replacingOccurrences(of: "\"name\": \"Keep\"", with: "\"name\": \"\(hostile)\"")
        let f = try Fixture(json: json)
        #expect(f.backend.deleteBookmarkFolder(target(.path(["Bookmarks Bar", "INJECTED"]))) == .notFound)
        #expect(f.backend.deleteBookmarkFolder(target(.path(["Bookmarks Bar", hostile]))) == .deleted(bookmarkCount: 1, subfolderCount: 0))
        #expect(!(try f.allIDs()).contains("11"))
    }

    @Test func locateReportsCountsAndAncestorsWithoutWriting() throws {
        let f = try Fixture()
        let before = try f.raw()
        let result = f.backend.locateBookmarkFolder(target(.path(["Bookmarks Bar", "Work", "Projects"])))
        #expect(result == .found(LocatedBookmarkFolder(
            id: "7", title: "Projects", ancestorTitles: ["Bookmarks Bar", "Work"], bookmarkCount: 2, subfolderCount: 1
        )))
        #expect(try f.raw() == before)
    }

    // MARK: - Extension-first decorator

    private final class FolderBridge: ExtensionBridgeServing, @unchecked Sendable {
        var result = false
        var sent: [(type: String, payload: [String: Any])] = []
        func snapshotView(for appName: String, profileCount: Int) -> ExtensionSnapshotView? { nil }
        func isConnected(appName: String) -> Bool { result }
        func sendCommand(appName: String, type: String, tabID: Int, extraPayload: [String: Any], timeout: TimeInterval) -> Bool { false }
        func sendBrowserCommand(appName: String, type: String, payload: [String: Any], timeout: TimeInterval) -> Bool {
            sent.append((type, payload))
            return result
        }
    }

    @Test func extensionGetsRemoveTreeCommandWithVerificationFields() throws {
        let f = try Fixture()
        let bridge = FolderBridge()
        bridge.result = true
        let backend = ExtensionBackedBackend(inner: f.backend, bridge: bridge)
        let outcome = backend.deleteBookmarkFolder(target(.path(["Bookmarks Bar", "Work"])))
        #expect(outcome == .deleted(bookmarkCount: 3, subfolderCount: 2))
        let command = try #require(bridge.sent.first)
        #expect(command.type == "deleteBookmarkFolder")
        #expect(command.payload["id"] as? String == "4")
        #expect(command.payload["title"] as? String == "Work")
        #expect(command.payload["ancestorTitles"] as? [String] == ["Bookmarks Bar"])
    }

    @Test func extensionFailureFallsBackToFileEdit() throws {
        let f = try Fixture()
        let bridge = FolderBridge()
        let backend = ExtensionBackedBackend(inner: f.backend, bridge: bridge)
        #expect(backend.deleteBookmarkFolder(target(.id("11"))) == .deleted(bookmarkCount: 1, subfolderCount: 0))
        #expect(!(try f.allIDs()).contains("11"))
    }

    @Test func rootFolderNeverReachesTheExtension() throws {
        let f = try Fixture()
        let bridge = FolderBridge()
        bridge.result = true
        let backend = ExtensionBackedBackend(inner: f.backend, bridge: bridge)
        #expect(backend.deleteBookmarkFolder(target(.id("1"))) == .rootFolder)
        #expect(backend.deleteBookmarkFolder(target(.path(["Other Bookmarks"]))) == .rootFolder)
        #expect(bridge.sent.isEmpty)
    }

    // MARK: - Read-only browsers + UI availability

    @Test func safariBackendRefusesFolderDelete() {
        let safari = SafariBackend()
        #expect(safari.deleteBookmarkFolder(target(.path(["Favorites", "Work"]))) == .readOnlyBrowser)
        #expect(safari.locateBookmarkFolder(target(.path(["Favorites", "Work"]))) == .failed(.readOnlyBrowser))
    }

    private func folder(_ id: String, browser: String = "Google Chrome", isRoot: Bool = false, synthesized: Bool = false, children: [BookmarkTreeNode] = []) -> BookmarkFolder {
        BookmarkFolder(id: "\(browser)|Default|\(id)", name: "F\(id)", browserName: browser, profileName: "Default",
                       children: children, isRoot: isRoot, isSynthesized: synthesized)
    }

    private func item(_ id: String) -> BookmarkTreeNode {
        .item(BookmarkItem(id: id, title: id, url: "https://example.com/\(id)", browserName: "Google Chrome",
                           profileName: "Default", dateAdded: nil, folderPath: ""))
    }

    @Test func availabilityPerFolderKind() {
        #expect(BookmarkFolderDeleteAvailability.of(folder("4")) == .allowed)
        #expect(BookmarkFolderDeleteAvailability.of(folder("1", isRoot: true)) == .hidden)
        #expect(BookmarkFolderDeleteAvailability.of(folder("x", browser: "Safari", synthesized: true))
                == .disabled(reason: "Safari bookmarks can't be changed from FastTab"))
        #expect(BookmarkFolderDeleteAvailability.of(folder("x", browser: "Firefox", synthesized: true))
                == .disabled(reason: BookmarkFolderDeleteCopy.readOnlyBrowser))
    }

    @Test func folderCountsAreRecursiveAndRawIDIsTheBrowserID() {
        let inner = folder("7", children: [item("8"), .folder(folder("9", children: [item("10")]))])
        let outer = folder("4", children: [item("5"), .folder(inner)])
        #expect(outer.totalBookmarkCount == 3)
        #expect(outer.totalSubfolderCount == 2)
        #expect(outer.rawID == "4")
        #expect(outer.folder(withID: "Google Chrome|Default|9")?.name == "F9")
        var root = folder("1", isRoot: true, children: [.folder(outer)])
        let removed = root.removeSubfolder(id: "Google Chrome|Default|7")
        #expect(removed)
        #expect(root.totalBookmarkCount == 1)
    }

    @MainActor @Test func storeFindsAndRemovesNestedFolder() {
        let defaults = UserDefaults(suiteName: "bmfolder-\(UUID().uuidString)")!
        let store = BookmarkTreeStore(defaults: defaults)
        let inner = folder("7", children: [item("8")])
        store.setRootFolders([folder("1", isRoot: true, children: [.folder(folder("4", children: [.folder(inner), item("5")]))])])
        #expect(store.folder(withID: "Google Chrome|Default|7")?.totalBookmarkCount == 1)
        #expect(store.removeFolder(id: "Google Chrome|Default|4"))
        #expect(store.folder(withID: "Google Chrome|Default|7") == nil)
        #expect(store.rootFolders.count == 1)
        #expect(!store.removeFolder(id: "Google Chrome|Default|1"))
    }

    @Test func confirmationCopyShowsCounts() {
        #expect(BookmarkFolderDeleteCopy.confirmation(folderName: "Work", bookmarkCount: 3, subfolderCount: 2)
                == "Delete folder \"Work\" and its 3 bookmarks (incl. 2 subfolders)? This can't be undone.")
        #expect(BookmarkFolderDeleteCopy.confirmation(folderName: "A", bookmarkCount: 1, subfolderCount: 0)
                == "Delete folder \"A\" and its 1 bookmark? This can't be undone.")
    }

    // MARK: - Sync wire + answers

    @Test func syncResponsesNeverClaimSuccessForAFailure() {
        #expect(BookmarkFolderDeleteCopy.syncResponse(for: .deleted(bookmarkCount: 3, subfolderCount: 1), browserName: "Google Chrome").status == .done)
        for outcome: BookmarkFolderDeleteOutcome in [.notFound, .rootFolder, .ambiguous, .readOnlyBrowser, .failed] {
            #expect(BookmarkFolderDeleteCopy.syncResponse(for: outcome, browserName: "Google Chrome").status != .done)
        }
        let safari = BookmarkFolderDeleteCopy.syncResponse(for: .readOnlyBrowser, browserName: "Safari")
        #expect(safari.status == .refused)
        #expect(safari.reason == "Safari bookmarks can't be changed from FastTab")
    }

    @Test func deleteFolderPayloadRoundTrips() throws {
        let payload = DeleteBookmarkFolderPayload(browserName: "Google Chrome", profileName: "Default", folderPath: ["Bookmarks Bar", "$(echo INJECTED)"])
        let decoded = try JSONDecoder().decode(DeleteBookmarkFolderPayload.self, from: JSONEncoder().encode(payload))
        #expect(decoded == payload)
        #expect(SyncCommandKind.deleteBookmarkFolder.rawValue == "deleteBookmarkFolder")
    }

    @Test func macDeviceRecordAdvertisesFolderDeleteAndLegacyRecordsDoNot() throws {
        let zone = CKRecordZone.ID(zoneName: "z", ownerName: CKCurrentUserDefaultName)
        let mac = SyncedDevice(id: "mac1", name: "Mac", modelName: "Mac", appVersion: "2.0", kind: .mac,
                               capabilities: SyncedDeviceCapability.currentMac)
        let decoded = try #require(SyncedDevice(from: mac.toRecord(zoneID: zone)))
        #expect(decoded.supports(SyncedDeviceCapability.deleteBookmarkFolder))

        let legacy = SyncedDevice(id: "mac2", name: "Old", modelName: "Mac", appVersion: "1.0")
        let legacyDecoded = try #require(SyncedDevice(from: legacy.toRecord(zoneID: zone)))
        #expect(!legacyDecoded.supports(SyncedDeviceCapability.deleteBookmarkFolder))

        // Caches written before the field existed still load.
        let oldJSON = #"{"id":"m","name":"n","modelName":"x","lastSeenAt":0,"appVersion":"1"}"#
        let cached = try JSONDecoder().decode(SyncedDevice.self, from: Data(oldJSON.utf8))
        #expect(cached.capabilities.isEmpty)
    }
}
