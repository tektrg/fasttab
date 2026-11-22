import Foundation
import Testing
@testable import FastTab

/// A Chromium profile has a folder name ("Profile 3") and a display name ("SSV"). Live tabs used to
/// carry the display name and bookmarks/history the folder name, so a custom view saved with one
/// never matched rows carrying the other: "Profile 3" showed no open tabs, and "SSV" lost its
/// bookmarks/history whenever the extension was offline. Pure; runs headless, also on Linux via
/// `scripts/test-profile-names-linux.sh` (compiles ProfileNames.swift alone).
@Suite("Profile names: folder vs display name")
struct ProfileNamesTests {
    struct P: Equatable { let directory: String; let displayName: String }
    let edge = [
        P(directory: "Default", displayName: "OSS"),
        P(directory: "Profile 3", displayName: "SSV"),
        P(directory: "Profile 4", displayName: "AptusFit"),
    ]

    private func pick(_ ref: String?) -> P? {
        ProfileNames.pick(ref, in: edge, directory: \.directory, displayName: \.displayName)
    }

    // MARK: Name resolution (bug A: stored references find the profile by either name)

    @Test func storedReferenceResolvesByFolderOrDisplayName() {
        #expect(pick("Profile 3") == edge[1])
        #expect(pick("SSV") == edge[1])
        #expect(pick(" aptusfit ") == edge[2])
        #expect(pick("profile 4") == edge[2])
        #expect(pick("Gone") == nil)
        #expect(pick("  ") == nil)
        #expect(pick(nil) == nil)
    }

    @Test func exactFolderWinsOverAnotherProfilesDisplayName() {
        let tricky = [P(directory: "Profile 1", displayName: "Default"), P(directory: "Default", displayName: "Home")]
        let hit = ProfileNames.pick("Default", in: tricky, directory: \.directory, displayName: \.displayName)
        #expect(hit == tricky[1])
    }

    @Test func tabNamesResolveDisplayNameFirst() {
        // Tab rows (and slots remembered from them) carry the display name. Edge's defaults show folder
        // "Default" as "Profile 1", so a pinned tab saved as "Profile 1" must reopen in "Default".
        let edgeDefaults = [P(directory: "Default", displayName: "Profile 1"), P(directory: "Profile 1", displayName: "Profile 2")]
        let tab = ProfileNames.pick("Profile 1", in: edgeDefaults, directory: \.directory, displayName: \.displayName,
                                    displayNameFirst: true)
        #expect(tab == edgeDefaults[0])
        let stored = ProfileNames.pick("Profile 1", in: edgeDefaults, directory: \.directory, displayName: \.displayName)
        #expect(stored == edgeDefaults[1])
        // A slot that saved a folder name still resolves.
        #expect(ProfileNames.pick("Default", in: edgeDefaults, directory: \.directory, displayName: \.displayName,
                                  displayNameFirst: true) == edgeDefaults[0])
    }

    // MARK: Filter matching (bug A + bug B)

    private func matches(_ selected: [String], display: String?, directory: String?) -> Bool {
        ProfileNames.matches(selectedKeys: ProfileNames.keys(selected), displayName: display, directory: directory)
    }

    @Test func oldViewSavedWithFolderNameStillMatchesDisplayNamedRows() {
        // Bug A: bookmarks/history now show "SSV"; a view saved as "Profile 3" keeps working.
        #expect(matches(["Profile 3"], display: "SSV", directory: "Profile 3"))
    }

    @Test func folderNameSelectionMatchesOpenTabs() {
        // Bug B: an extension tab of Profile 3 carries display "SSV" + folder "Profile 3".
        #expect(matches(["Profile 3"], display: "SSV", directory: "Profile 3"))
        #expect(matches(["profile 3"], display: "SSV", directory: "Profile 3"))
    }

    @Test func displayNameSelectionMatchesCaseInsensitively() {
        #expect(matches(["ssv"], display: "SSV", directory: "Profile 3"))
        #expect(matches([" Ssv "], display: "SSV", directory: nil))
        #expect(matches(["aptus", "ssv"], display: "SSV", directory: "Profile 3"))
    }

    @Test func otherProfilesAndUnknownRowsDoNotMatch() {
        #expect(!matches(["Profile 3"], display: "AptusFit", directory: "Profile 4"))
        #expect(!matches(["SSV"], display: nil, directory: nil))
        #expect(!matches(["SSV"], display: "SSV-old", directory: "Profile 9"))
    }

    @Test func displayNameWinsWhenItIsAlsoAnotherProfilesFolder() {
        // Edge's default naming: folder "Default" shows as "Profile 1", folder "Profile 1" as "Profile 2".
        let known = ProfileNames.keys(["Profile 1", "Profile 2"])
        func edge(_ selected: [String], display: String, directory: String) -> Bool {
            ProfileNames.matches(selectedKeys: ProfileNames.keys(selected), displayName: display,
                                 directory: directory, displayNameKeys: known)
        }
        #expect(edge(["Profile 1"], display: "Profile 1", directory: "Default"))
        #expect(!edge(["Profile 1"], display: "Profile 2", directory: "Profile 1"))
        #expect(edge(["Default"], display: "Profile 1", directory: "Default"))
        #expect(edge(["Profile 2"], display: "Profile 2", directory: "Profile 1"))
    }

    @Test func emptySelectionMatchesEverything() {
        #expect(matches([], display: nil, directory: nil))
        #expect(matches([" "], display: "SSV", directory: "Profile 3"))
    }

    // MARK: Custom view menu (one chip per profile, old folder-name selections fold in)

    private let sources: [ProfileNames.Source] = [
        .init(browserName: "Microsoft Edge", displayName: "SSV", directory: "Profile 3"),          // live tab
        .init(browserName: "Microsoft Edge", displayName: "SSV", directory: "Profile 3"),          // bookmark
        .init(browserName: "Microsoft Edge", displayName: "AptusFit", directory: "Profile 4"),     // history
        .init(browserName: "Microsoft Edge", displayName: "AptusFit", directory: nil),             // tab, folder unknown yet
        .init(browserName: "Microsoft Edge", displayName: nil, directory: nil),
    ]

    @Test func menuShowsDisplayNamesOnceWithFolderAliases() {
        let options = CustomViewProfileOption.options(from: sources, selected: [])
        #expect(options.map(\.name) == ["AptusFit", "SSV"])
        #expect(options.first { $0.name == "SSV" }?.aliases == ["Profile 3"])
    }

    @Test func oldFolderSelectionTicksTheDisplayChipInsteadOfAddingOne() {
        let options = CustomViewProfileOption.options(from: sources, selected: ["Profile 3", "Gone"])
        #expect(options.map(\.name) == ["AptusFit", "Gone", "SSV"])
        let ssv = options.first { $0.name == "SSV" }!
        #expect(ssv.isSelected(in: ["Profile 3"]))
        #expect(ssv.isSelected(in: ["ssv"]))
        #expect(!ssv.isSelected(in: ["AptusFit"]))
    }

    @Test func folderAliasIsDroppedOnlyWhenTheSameBrowserUsesItAsADisplayName() {
        // Edge (defaults): folder "Default" shows "Profile 1". Chrome: folder "Profile 1" is "Work".
        let options = CustomViewProfileOption.options(from: [
            .init(browserName: "Microsoft Edge", displayName: "Profile 1", directory: "Default"),
            .init(browserName: "Microsoft Edge", displayName: "Profile 2", directory: "Profile 1"),
            .init(browserName: "Google Chrome", displayName: "Work", directory: "Profile 1"),
        ], selected: [])
        #expect(options.first { $0.name == "Work" }?.aliases == ["Profile 1"])
        #expect(options.first { $0.name == "Profile 2" }?.aliases == [])
    }

    @Test func togglingAChipRemovesEveryNameOfThatProfile() {
        let ssv = CustomViewProfileOption(name: "SSV", browsers: ["Microsoft Edge"], showsBrowsers: false, aliases: ["Profile 3"])
        #expect(ssv.toggled(in: ["Profile 3", "AptusFit"]) == ["AptusFit"])
        #expect(ssv.toggled(in: ["SSV", "profile 3"]) == [])
        #expect(ssv.toggled(in: ["AptusFit"]) == ["AptusFit", "SSV"])
    }
}
