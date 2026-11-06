import Foundation
import Testing
@testable import FastTab

/// `CustomView` persistence shape, domain normalization, and `CustomViewStore`.
@MainActor
struct CustomViewModelTests {
    // MARK: Codable

    @Test func fullViewRoundTripsThroughJSON() throws {
        let view = CustomView(
            name: "Work GitHub",
            iconName: "hammer",
            types: [.tab, .history],
            profiles: ["Work"],
            domains: ["github.com", "gitlab.com"],
            keywords: "pull request",
            lastVisited: .olderThan(7 * 86_400),
            pinned: .exclude,
            semanticPrompt: "code reviews waiting on me",
            groupBy: .domain
        )
        let data = try JSONEncoder().encode(view)
        #expect(try JSONDecoder().decode(CustomView.self, from: data) == view)
    }

    @Test(arguments: [LastVisitedRule.any, .within(3_600), .olderThan(90 * 86_400)])
    func lastVisitedRuleRoundTrips(rule: LastVisitedRule) throws {
        let data = try JSONEncoder().encode(rule)
        #expect(try JSONDecoder().decode(LastVisitedRule.self, from: data) == rule)
    }

    @Test func decodingMinimalJSONFillsDefaults() throws {
        let id = UUID()
        let json = #"{"id":"\#(id.uuidString)","name":"Reading"}"#
        let view = try JSONDecoder().decode(CustomView.self, from: Data(json.utf8))
        #expect(view == CustomView(id: id, name: "Reading"))
        #expect(view.iconName == CustomView.defaultIconName)
        #expect(view.effectiveTypes == [.tab, .bookmark, .history])
    }

    @Test func decodingToleratesUnknownValuesAndKeys() throws {
        let json = """
        {"name":"Future","types":["tab","readingList","sent"],"groupBy":"weekday",
         "lastVisited":{"kind":"between","seconds":5},"newField":42}
        """
        let view = try JSONDecoder().decode(CustomView.self, from: Data(json.utf8))
        #expect(view.name == "Future")
        #expect(view.types == [.tab]) // unknown + disallowed types dropped
        #expect(view.groupBy == .none)
        #expect(view.lastVisited == .any)
    }

    @Test func typesOutsideAllowedSetAreDropped() {
        var view = CustomView(name: "x", types: [.sent, .bookmark, .fastTabList])
        #expect(view.types == [.bookmark])
        view.types = [.fastTabList]
        #expect(view.types.isEmpty)
        #expect(view.effectiveTypes == CustomView.allowedTypes)
    }

    @Test func displayNames() {
        #expect(LastVisitedRule.any.displayName == "Any time")
        #expect(LastVisitedRule.within(7 * 86_400).displayName == "Within 7 days")
        #expect(LastVisitedRule.olderThan(3_600).displayName == "Older than 1 hour")
        #expect(LastVisitedRule.presets.map(\.seconds) == [3_600, 86_400, 604_800, 2_592_000, 7_776_000])
    }

    // MARK: Domain normalization

    @Test(arguments: [
        ("github.com", "github.com"),
        ("GitHub.com", "github.com"),
        ("https://www.github.com/x/y?z=1#f", "github.com"),
        ("*.google.com", "google.com"),
        ("https://*.google.com/", "google.com"),
        (".example.org.", "example.org"),
        ("  docs.swift.org:8080/path ", "docs.swift.org"),
        ("user:pw@host.dev", "host.dev"),
        ("www.apple.com", "apple.com"),
    ])
    func normalizesUserDomainInput(raw: String, expected: String) {
        #expect(CustomViewDomain.normalize(raw) == expected)
    }

    @Test(arguments: ["", "   ", "https://", "*.", "two words.com"])
    func rejectsNonHosts(raw: String) {
        #expect(CustomViewDomain.normalize(raw) == nil)
    }

    @Test func subdomainMatching() {
        #expect(CustomViewDomain.host("github.com", isWithin: "github.com"))
        #expect(CustomViewDomain.host("gist.github.com", isWithin: "github.com"))
        #expect(CustomViewDomain.host("a.b.github.com", isWithin: "github.com"))
        #expect(!CustomViewDomain.host("notgithub.com", isWithin: "github.com"))
        #expect(!CustomViewDomain.host("github.com.evil.io", isWithin: "github.com"))
        #expect(!CustomViewDomain.host("github.com", isWithin: "gist.github.com"))
        #expect(CustomViewDomain.host(ofURL: "https://WWW.GitHub.com/a") == "github.com")
        #expect(CustomViewDomain.host(ofURL: "/Users/me/Documents") == nil)
    }

    // MARK: Store

    private func scratchDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test.fasttab.customViews.\(UUID().uuidString)")!
    }

    @Test func storePersistsAcrossInstances() {
        let defaults = scratchDefaults()
        let store = CustomViewStore(defaults: defaults)
        let a = CustomView(name: "A", domains: ["github.com"])
        let b = CustomView(name: "B", lastVisited: .within(3_600))
        store.add(a)
        store.add(b)
        #expect(CustomViewStore(defaults: defaults).views == [a, b])

        var edited = a
        edited.name = "A2"
        store.update(edited)
        store.delete(id: b.id)
        let reloaded = CustomViewStore(defaults: defaults)
        #expect(reloaded.views == [edited])
        #expect(reloaded.view(id: a.id)?.name == "A2")
        #expect(reloaded.view(id: b.id) == nil)
    }

    @Test func updateOfUnknownIdIsNoOp() {
        let store = CustomViewStore(defaults: scratchDefaults())
        store.update(CustomView(name: "ghost"))
        #expect(store.views.isEmpty)
    }

    @Test func moveFollowsSwiftUIOnMoveContract() {
        let defaults = scratchDefaults()
        let store = CustomViewStore(defaults: defaults)
        let views = ["A", "B", "C", "D"].map { CustomView(name: $0) }
        views.forEach(store.add)

        store.move(fromOffsets: [0], toOffset: 3) // A before D
        #expect(store.views.map(\.name) == ["B", "C", "A", "D"])
        store.move(fromOffsets: [3], toOffset: 0) // D to front
        #expect(store.views.map(\.name) == ["D", "B", "C", "A"])
        store.move(fromOffsets: [1, 2], toOffset: 4) // B, C to end
        #expect(store.views.map(\.name) == ["D", "A", "B", "C"])
        #expect(CustomViewStore(defaults: defaults).views.map(\.name) == ["D", "A", "B", "C"])
    }

    @Test func malformedEntryDropsOnlyItself() throws {
        let defaults = scratchDefaults()
        let good = CustomView(name: "Good")
        let goodJSON = String(decoding: try JSONEncoder().encode(good), as: UTF8.self)
        defaults.set(Data("[\(goodJSON), \"garbage\", 7]".utf8), forKey: CustomViewStore.defaultsKey)
        #expect(CustomViewStore(defaults: defaults).views == [good])
    }

    @Test(arguments: PinnedRule.allCases)
    func pinnedRuleRoundTrips(rule: PinnedRule) throws {
        let view = CustomView(name: "p", pinned: rule)
        #expect(try JSONDecoder().decode(CustomView.self, from: JSONEncoder().encode(view)).pinned == rule)
    }

    /// A view saved before the Pinned filter existed (no "pinned" key).
    @Test func oldSavedViewWithoutPinnedDecodesAsAny() throws {
        let json = """
        {"id":"\(UUID().uuidString)","name":"Old","iconName":"star","types":["tab"],"profiles":["Work"],
         "domains":["github.com"],"keywords":"pr","lastVisited":{"kind":"within","seconds":604800},
         "semanticPrompt":"","groupBy":"domain"}
        """
        let view = try JSONDecoder().decode(CustomView.self, from: Data(json.utf8))
        #expect(view.pinned == .any)
        #expect(view.name == "Old")
        #expect(view.profiles == ["Work"])
        #expect(view.groupBy == .domain)
    }

    @Test func unknownPinnedValueFallsBackToAny() throws {
        let json = #"{"name":"Future","pinned":"pinnedInGroup"}"#
        #expect(try JSONDecoder().decode(CustomView.self, from: Data(json.utf8)).pinned == .any)
    }
}
