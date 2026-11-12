import Foundation
import Testing
@testable import FastTab

/// Users' saved views (`FastTab.customViews.v1`, a flat JSON array written before the shared
/// `SavedView` model) must keep loading. The "Last visited" filter and group-by were removed
/// (2026-11-12, inaccurate data): old JSON still decodes, the filter is dropped silently and
/// `groupBy: "lastVisited"` falls back to none; everything else re-encodes unchanged.
@MainActor
struct CustomViewStoredFormatTests {
    /// The exact shape the pre-`IndieSavedViews` `CustomView` encoder wrote.
    static let fixture = #"""
    [
      {"id":"7F1C6A52-2B8E-4D63-9A4F-1E2D3C4B5A60","name":"Work GitHub","iconName":"hammer",
       "types":["history","tab"],"profiles":["Work"],"domains":["github.com","*issue*"],
       "keywords":"pull request","lastVisited":{"kind":"olderThan","seconds":604800},
       "pinned":"exclude","semanticPrompt":"code reviews","groupBy":"domain"},
      {"id":"0A9B8C7D-6E5F-4A3B-2C1D-0E9F8A7B6C5D","name":"Recent","iconName":"clock",
       "types":[],"profiles":[],"domains":[],"keywords":"/^PR-\\d+/",
       "lastVisited":{"kind":"any"},"pinned":"any","semanticPrompt":"","groupBy":"lastVisited"}
    ]
    """#

    private func scratchDefaults() -> UserDefaults {
        let name = "CustomViewStoredFormatTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func fixtureLoadsThroughTheStore() {
        let defaults = scratchDefaults()
        defaults.set(Data(Self.fixture.utf8), forKey: "FastTab.customViews.v1")
        let views = CustomViewStore(defaults: defaults).views
        #expect(views.count == 2)
        let work = views[0]
        #expect(work.id == UUID(uuidString: "7F1C6A52-2B8E-4D63-9A4F-1E2D3C4B5A60"))
        #expect(work.name == "Work GitHub")
        #expect(work.iconName == "hammer")
        #expect(work.types == [.tab, .history])
        #expect(work.profiles == ["Work"])
        #expect(work.domains == ["github.com", "*issue*"])
        #expect(work.keywords == "pull request")
        #expect(work.pinned == .exclude)
        #expect(work.semanticPrompt == "code reviews")
        #expect(work.groupBy == .domain)
        #expect(views[1].keywords == #"/^PR-\d+/"#)
        #expect(views[1].groupBy == .none)
    }

    /// The fixture as this build writes it back: no `lastVisited` key (an older build reads
    /// that as "Any time"), and the removed group-by saved as "none".
    static var expectedRewrite: NSArray {
        let rows = (try! JSONSerialization.jsonObject(with: Data(fixture.utf8)) as! [[String: Any]]).map { row in
            var row = row
            row.removeValue(forKey: "lastVisited")
            if row["groupBy"] as? String == "lastVisited" { row["groupBy"] = "none" }
            return row
        }
        return rows as NSArray
    }

    @Test func reEncodesWithoutTheRemovedLastVisitedOption() throws {
        let views = try JSONDecoder().decode([CustomView].self, from: Data(Self.fixture.utf8))
        let reencoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(views)) as? NSArray
        #expect(reencoded == Self.expectedRewrite)
        let text = String(decoding: try JSONEncoder().encode(views), as: UTF8.self)
        #expect(!text.contains("lastVisited"))
    }

    @Test func lastVisitedIsNoLongerAGroupByChoice() {
        #expect(CustomViewGroupBy.allCases == [.none, .domain])
    }

    @Test func storeWritesTheSameFormat() throws {
        let defaults = scratchDefaults()
        defaults.set(Data(Self.fixture.utf8), forKey: "FastTab.customViews.v1")
        let store = CustomViewStore(defaults: defaults)
        store.move(fromOffsets: [1], toOffset: 0)
        store.move(fromOffsets: [1], toOffset: 0)  // back to the original order, persisted
        let written = try #require(defaults.data(forKey: "FastTab.customViews.v1"))
        #expect(try JSONSerialization.jsonObject(with: written) as? NSArray == Self.expectedRewrite)
    }
}
