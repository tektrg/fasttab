import Foundation
import Testing
@testable import FastTab

/// Profile names end to end on the Mac: Chromium rows carry the display name plus the folder, writes
/// accept either name, and a custom view saved with either name returns open tabs, bookmarks and
/// history of that profile. Temp-dir fixtures only — never a real browser profile.
@Suite struct ProfileNamesBackendTests {
    private final class Fixture {
        let base: URL
        let backend: ChromiumBackend

        init() throws {
            base = FileManager.default.temporaryDirectory.appendingPathComponent("profnames-\(UUID().uuidString)")
            let bookmarks = """
            {"roots":{"bookmark_bar":{"children":[{"id":"5","name":"Jira","type":"url","url":"https://jira.example.com/"}],
            "id":"1","name":"Bookmarks Bar","type":"folder"},"other":{"children":[],"id":"2","name":"Other","type":"folder"}},"version":1}
            """
            for folder in ["Default", "Profile 3"] {
                let dir = base.appendingPathComponent(folder, isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try bookmarks.write(to: dir.appendingPathComponent("Bookmarks"), atomically: true, encoding: .utf8)
            }
            let state = #"{"profile":{"info_cache":{"Default":{"name":"OSS"},"Profile 3":{"name":"SSV"}}}}"#
            try state.write(to: base.appendingPathComponent("Local State"), atomically: true, encoding: .utf8)
            backend = ChromiumBackend(appName: "Microsoft Edge", bundleIdentifier: "com.microsoft.edgemac", supportDirectory: base.path)
        }

        deinit { try? FileManager.default.removeItem(at: base) }
    }

    @Test func bookmarksCarryDisplayNameAndFolderWithStableIDs() throws {
        let fixture = try Fixture()
        let ssv = try #require(fixture.backend.fetchAllBookmarks().first { $0.profileDirectory == "Profile 3" })
        #expect(ssv.profileName == "SSV")
        #expect(ssv.id.hasSuffix("|Profile 3"))   // same id as before display names
        let tree = fixture.backend.fetchBookmarkTree()
        #expect(tree.contains { $0.profileName == "SSV" && $0.id.contains("|Profile 3|") })
    }

    @Test func writesFindTheProfileByDisplayNameOrFolder() throws {
        let fixture = try Fixture()
        #expect(fixture.backend.insertBookmark(title: "A", url: "https://a.example.com/", dateAdded: nil, profileName: "SSV", folderPath: []))
        #expect(fixture.backend.insertBookmark(title: "B", url: "https://b.example.com/", dateAdded: nil, profileName: "Profile 3", folderPath: []))
        let urls = fixture.backend.fetchAllBookmarks().filter { $0.profileDirectory == "Profile 3" }.map(\.url)
        #expect(urls.contains("https://a.example.com/") && urls.contains("https://b.example.com/"))
        #expect(!fixture.backend.fetchAllBookmarks().contains { $0.profileName == "OSS" && $0.url.hasPrefix("https://a.") })
    }

    @Test func windowTitleResolvesToBothNames() throws {
        let fixture = try Fixture()
        let known = fixture.backend.profiles()
        let hit = ChromiumBackend.windowProfile(title: "Inbox - SSV", among: known)
        #expect(hit.displayName == "SSV" && hit.directory == "Profile 3")
        let guess = ChromiumBackend.windowProfile(title: "Inbox - Someone", among: known)
        #expect(guess.displayName == "Someone" && guess.directory == nil)
    }

    // MARK: Pinned tabs reopened after closing (ghosts)

    /// Edge's default naming: folder "Default" shows "Profile 1", folder "Profile 1" shows "Profile 2".
    private func edgeDefaults() throws -> (ChromiumBackend, URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("edgedefaults-\(UUID().uuidString)")
        for folder in ["Default", "Profile 1"] {
            let dir = base.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try #"{"roots":{}}"#.write(to: dir.appendingPathComponent("Bookmarks"), atomically: true, encoding: .utf8)
        }
        let state = #"{"profile":{"info_cache":{"Default":{"name":"Profile 1"},"Profile 1":{"name":"Profile 2"}}}}"#
        try state.write(to: base.appendingPathComponent("Local State"), atomically: true, encoding: .utf8)
        return (ChromiumBackend(appName: "Microsoft Edge", bundleIdentifier: "com.microsoft.edgemac", supportDirectory: base.path), base)
    }

    @Test func ghostSavedWithDisplayNameReopensInThatProfile() throws {
        let (backend, base) = try edgeDefaults()
        defer { try? FileManager.default.removeItem(at: base) }
        // A slot saved before slots kept the folder: only the tab's display name "Profile 1".
        let oldGhost = OrderedTabSlot(url: "https://a.example.com/", title: "A", browserName: "Microsoft Edge",
                                      profileName: "Profile 1", state: .ghost).asSearchResult
        #expect(backend.launchDirectory(for: oldGhost) == "Default")
        let newGhost = OrderedTabSlot(url: "https://a.example.com/", title: "A", browserName: "Microsoft Edge",
                                      profileName: "Profile 2", profileDirectory: "Profile 1", state: .ghost).asSearchResult
        #expect(backend.launchDirectory(for: newGhost) == "Profile 1")
        // Non-tab rows name folders first (phone commands, stored references).
        let bookmark = BrowserSearchResult(title: "B", url: "https://b.example.com/", browserName: "Microsoft Edge",
                                           type: .bookmark, timestamp: Date(), profileName: "Profile 1")
        #expect(backend.launchDirectory(for: bookmark) == "Profile 1")
        let gone = BrowserSearchResult(title: "C", url: "https://c.example.com/", browserName: "Microsoft Edge",
                                       type: .tab, timestamp: Date(), profileName: "Profile 1", profileDirectory: "Profile 9")
        #expect(backend.launchDirectory(for: gone) == nil)
    }

    @Test func slotsRememberTheFolderAndOldSlotsStillDecode() throws {
        let tab = row(.tab, "ssvtab", display: "SSV", folder: "Profile 3")
        let slots = MyOrderReconciler.reconcile(currentSlots: [], liveTabs: [tab], runningBrowsers: ["Microsoft Edge"],
                                                pendingCloses: []).slots
        let slot = try #require(slots.first)
        #expect(slot.profileName == "SSV" && slot.profileDirectory == "Profile 3")
        let decoded = try JSONDecoder().decode(OrderedTabSlot.self, from: JSONEncoder().encode(slot))
        #expect(decoded.profileDirectory == "Profile 3")
        #expect(decoded.asSearchResult.profileDirectory == "Profile 3")
        let old = #"{"slotID":"\#(UUID().uuidString)","url":"https://a.com","title":"A","browserName":"Microsoft Edge","profileName":"SSV","state":"ghost"}"#
        let oldSlot = try JSONDecoder().decode(OrderedTabSlot.self, from: Data(old.utf8))
        #expect(oldSlot.profileName == "SSV" && oldSlot.profileDirectory == nil)
    }

    // MARK: Custom view (bug B: "Profile 3" must show open tabs too)

    private func row(_ type: BrowserResultType, _ title: String, display: String?, folder: String?) -> BrowserSearchResult {
        BrowserSearchResult(
            title: title, url: "https://\(title).example.com/", browserName: "Microsoft Edge", type: type,
            timestamp: Date(), windowIndex: type == .tab ? 1 : nil, tabIndex: type == .tab ? 1 : nil,
            bookmarkID: type == .bookmark ? title : nil, profileName: display, profileDirectory: folder
        )
    }

    private var candidates: [BrowserSearchResult] {
        [
            row(.tab, "ssvtab", display: "SSV", folder: "Profile 3"),
            row(.bookmark, "ssvbm", display: "SSV", folder: "Profile 3"),
            row(.history, "ssvhist", display: "SSV", folder: "Profile 3"),
            row(.tab, "aptustab", display: "AptusFit", folder: "Profile 4"),
        ]
    }

    @Test func viewSavedWithFolderNameShowsOpenTabsBookmarksAndHistory() {
        let titles = Set(CustomViewFilter.evaluate(CustomView(name: "v", profiles: ["Profile 3"]), candidates: candidates).map(\.result.title))
        #expect(titles == ["ssvtab", "ssvbm", "ssvhist"])
    }

    @Test func viewSavedWithDisplayNameShowsTheSameRows() {
        let titles = Set(CustomViewFilter.evaluate(CustomView(name: "v", profiles: ["ssv"]), candidates: candidates).map(\.result.title))
        #expect(titles == ["ssvtab", "ssvbm", "ssvhist"])
    }

    @Test func edgeDefaultNamesPickTheProfileShownInTheMenu() {
        // Edge: folder "Default" shows as "Profile 1", folder "Profile 1" as "Profile 2".
        let rows = [
            row(.tab, "deftab", display: "Profile 1", folder: "Default"),
            row(.bookmark, "defbm", display: "Profile 1", folder: "Default"),
            row(.bookmark, "p1bm", display: "Profile 2", folder: "Profile 1"),
        ]
        let titles = Set(CustomViewFilter.evaluate(CustomView(name: "v", profiles: ["Profile 1"]), candidates: rows).map(\.result.title))
        #expect(titles == ["deftab", "defbm"])
    }

    @Test func sameFolderNameInAnotherBrowserIsNotBlockedByEdgeDisplayNames() {
        // Edge folder "Default" shows "Profile 1"; Chrome folder "Profile 1" is "Work". An old view
        // saved as "Profile 1" (Chrome's folder chip, or Edge's display chip) keeps both, as before.
        let rows = [
            row(.tab, "edgedef", display: "Profile 1", folder: "Default"),
            BrowserSearchResult(title: "chromework", url: "https://chromework.example.com/", browserName: "Google Chrome",
                                type: .bookmark, timestamp: Date(), bookmarkID: "9", profileName: "Work", profileDirectory: "Profile 1"),
        ]
        let titles = Set(CustomViewFilter.evaluate(CustomView(name: "v", profiles: ["Profile 1"]), candidates: rows).map(\.result.title))
        #expect(titles == ["edgedef", "chromework"])
    }

    @Test func settingsBookmarkRowKeepsTheFolderForDeletes() throws {
        let fixture = try Fixture()
        let folder = try #require(fixture.backend.fetchBookmarkTree().first { $0.profileName == "SSV" })
        #expect(folder.profileDirectory == "Profile 3")
        guard case .item(let item) = try #require(folder.children.first) else { Issue.record("no item"); return }
        let result = item.asSearchResult
        #expect(result.profileDirectory == "Profile 3")
        // Same id as the cached search row, so a delete also clears it from results.
        #expect(fixture.backend.fetchAllBookmarks().contains { $0.id == result.id })
    }

    @MainActor
    @Test func menuShowsOneChipPerProfileAndTicksOldFolderSelections() throws {
        let options = CustomViewProfileOption.options(from: candidates, selected: ["Profile 3"])
        #expect(options.map(\.name) == ["AptusFit", "SSV"])
        var draft = CustomViewDraft(view: CustomView(name: "v", profiles: ["Profile 3"]))
        let ssv = try #require(options.first { $0.name == "SSV" })
        #expect(draft.isProfileSelected(ssv))
        #expect(CustomViewEditorForm.profileMenuTitle(selected: draft.profiles, options: options) == "SSV")
        draft.toggleProfile(ssv)
        #expect(draft.profiles.isEmpty)
    }
}
