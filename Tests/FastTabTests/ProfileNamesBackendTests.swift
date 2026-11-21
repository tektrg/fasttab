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
