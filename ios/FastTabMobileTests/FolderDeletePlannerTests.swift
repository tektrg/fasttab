import XCTest
import FastTabSync
@testable import FastTabMobile

/// iPhone whole-folder delete: which folders offer it, one command per browser
/// profile, and an old Mac (no capability) gets nothing instead of a silent drop.
final class FolderDeletePlannerTests: XCTestCase {
    private let newMac = SyncedDevice(id: "mac", name: "Studio", modelName: "Mac", appVersion: "2",
                                      capabilities: SyncedDeviceCapability.currentMac)
    private let oldMac = SyncedDevice(id: "mac", name: "Old Air", modelName: "Mac", appVersion: "1")

    private func tree(_ blobs: [SyncedBookmarkBlob]) -> [BookmarkTreeNode] {
        BookmarkTreeBuilder.buildTree(from: blobs)
    }

    private func find(_ title: String, in nodes: [BookmarkTreeNode]) -> BookmarkTreeNode? {
        for node in nodes {
            if node.isFolder && node.title == title { return node }
            if let hit = find(title, in: node.children ?? []) { return hit }
        }
        return nil
    }

    private let chrome = SyncedBookmarkBlob(deviceID: "mac", browserName: "Google Chrome", profileName: "Default", bookmarks: [
        SyncedBookmarkItem(id: "5", title: "a", url: "https://example.com/a", folderPath: "Bookmarks Bar / Work"),
        SyncedBookmarkItem(id: "8", title: "b", url: "https://example.com/b", folderPath: "Bookmarks Bar / Work / Projects"),
        SyncedBookmarkItem(id: "10", title: "c", url: "https://example.com/c", folderPath: "Bookmarks Bar / Work / Projects / Deep"),
        SyncedBookmarkItem(id: "12", title: "d", url: "https://example.com/d", folderPath: "Bookmarks Bar / Keep")
    ])

    func testOneRequestForTheWholeTreeWithAllLeavesCovered() throws {
        let work = try XCTUnwrap(find("Work", in: tree([chrome])))
        guard case .send(let requests) = FolderDeletePlanner.plan(for: work, devices: [newMac]) else {
            return XCTFail("expected send")
        }
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].folderPath, ["Bookmarks Bar", "Work"])
        XCTAssertEqual(Set(requests[0].bookmarkIDs), ["5", "8", "10"])
        XCTAssertEqual(requests[0].source.profileName, "Default")
        XCTAssertEqual(FolderDeletePlanner.subfolderCount(of: work), 2)
    }

    func testOldMacIsToldToUpdateInsteadOfSilentDrop() throws {
        let work = try XCTUnwrap(find("Work", in: tree([chrome])))
        XCTAssertEqual(FolderDeletePlanner.plan(for: work, devices: [oldMac]), .macNeedsUpdate(macName: "Old Air"))
        XCTAssertEqual(FolderDeletePlanner.plan(for: work, devices: []), .macNeedsUpdate(macName: "your Mac"))
    }

    func testRootAndSafariFoldersAreBlocked() throws {
        let nodes = tree([chrome])
        let bar = try XCTUnwrap(find("Bookmarks Bar", in: nodes))
        XCTAssertEqual(FolderDeletePlanner.plan(for: bar, devices: [newMac]), .notDeletable(reason: FolderDeletePlanner.rootReason))

        let safari = SyncedBookmarkBlob(deviceID: "mac", browserName: "Safari", profileName: "Default", bookmarks: [
            SyncedBookmarkItem(id: "s1", title: "s", url: "https://example.com/s", folderPath: "Favorites / Reading")
        ])
        let reading = try XCTUnwrap(find("Reading", in: tree([safari])))
        XCTAssertEqual(FolderDeletePlanner.blockReason(for: reading), "Safari bookmarks can't be changed from FastTab")
    }

    func testFolderSpanningTwoProfilesSendsOnePerProfile() throws {
        let other = SyncedBookmarkBlob(deviceID: "mac", browserName: "Google Chrome", profileName: "Profile 1", bookmarks: [
            SyncedBookmarkItem(id: "5", title: "x", url: "https://example.com/x", folderPath: "Bookmarks Bar / Work")
        ])
        let work = try XCTUnwrap(find("Work", in: tree([chrome, other])))
        guard case .send(let requests) = FolderDeletePlanner.plan(for: work, devices: [newMac]) else {
            return XCTFail("expected send")
        }
        XCTAssertEqual(Set(requests.map(\.source.profileName)), ["Default", "Profile 1"])
    }

    func testConfirmationCopy() {
        XCTAssertEqual(FolderDeletePlanner.confirmation(folderName: "Work", bookmarkCount: 3, subfolderCount: 2),
                       "Delete folder \"Work\" and its 3 bookmarks (incl. 2 subfolders)? This can't be undone.")
    }

    func testFolderPendingActionHidesEveryCoveredLeaf() {
        let action = PendingBookmarkAction(blobID: "b", bookmarkID: "folder:Bar/Work", commandID: "c",
                                           bookmarkTitle: "Work", kind: .delete, coveredBookmarkIDs: ["5", "8"])
        XCTAssertEqual(action.hideKeys, ["b#5", "b#8"])
        XCTAssertEqual(action.bookmarkCount, 2)
    }
}
