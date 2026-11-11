import Foundation
import Testing
import CommandBarKit
import IndieSavedViews
@testable import AgentBar

/// Agent Bar saved views: criteria matching, grouping, storage, page switching, search patterns.
@MainActor
struct AgentSavedViewTests {
    typealias F = AgentListFixtures

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "AgentBarSavedViewTests.\(UUID().uuidString)")!
    }

    private let snapshot = F.snapshot([
        F.agent("n1", label: "pog-chief", project: "AptusFit", cwd: "/Users/me/01_Project/aptusfit", section: .needsYou, secondsInStatus: 60),
        F.agent("w1", label: "worker-a", project: "Parklet", cwd: "/Users/me/01_Project/jevdump", section: .working, secondsInStatus: 3_600 * 30),
        F.agent("w2", label: "worker-b", project: "AptusFit", cwd: "/Users/me/01_Project/aptusfit", section: .working, secondsInStatus: 300),
        F.agent("p1", label: "loose", project: nil, cwd: nil, section: .parked, secondsInStatus: nil)
    ])

    private func view(_ criteria: AgentViewCriteria = AgentViewCriteria(), keywords: String = "", groupBy: AgentViewGroupBy = .none) -> AgentSavedView {
        AgentSavedView(name: "V", keywords: keywords, groupBy: groupBy, criteria: criteria)
    }

    private func ids(_ view: AgentSavedView?, query: String = "") -> [String] {
        AgentListBuilder.presentation(snapshot: snapshot, query: query, frecency: [:], now: F.now, view: view).agents.map(\.id)
    }

    // MARK: Criteria

    @Test func emptyCriteriaKeepsEveryAgent() {
        #expect(Set(ids(view())) == ["n1", "w1", "w2", "p1"])
    }

    @Test func namesMatchLabelOrFolderWithPatterns() {
        #expect(ids(view(AgentViewCriteria(names: ["pog-*"]))) == ["n1"])
        #expect(Set(ids(view(AgentViewCriteria(names: ["/jevdump$/"])))) == ["w1"])
        #expect(Set(ids(view(AgentViewCriteria(names: ["aptusfit"])))) == ["n1", "w2"])
        #expect(ids(view(AgentViewCriteria(names: ["/[/"]))).isEmpty)
    }

    @Test func projectsSectionsAndActivityAreAnded() {
        #expect(Set(ids(view(AgentViewCriteria(projects: ["aptusfit"])))) == ["n1", "w2"])
        #expect(ids(view(AgentViewCriteria(projects: ["AptusFit"], sections: [.working]))) == ["w2"])
        // p1 has no activity reading, w1 is 30h old.
        #expect(Set(ids(view(AgentViewCriteria(activeWithinMinutes: 60)))) == ["n1", "w2"])
    }

    @Test func keywordsSeeTheFolder() {
        #expect(Set(ids(view(keywords: "*01_project/jev*"))) == ["w1"])
        #expect(Set(ids(view(keywords: "worker aptusfit"))) == ["w2"])
    }

    @Test func allPageIsUnchangedWithoutAView() {
        let all = AgentListBuilder.presentation(snapshot: snapshot, query: "", frecency: [:], now: F.now)
        let explicitNil = AgentListBuilder.presentation(snapshot: snapshot, query: "", frecency: [:], now: F.now, view: nil)
        #expect(all == explicitNil)
        #expect(all.rows.map(\.id).first == "section-0")
    }

    @Test func emptyViewSaysNoMatches() {
        let p = AgentListBuilder.presentation(snapshot: snapshot, query: "", frecency: [:], now: F.now,
                                              view: view(AgentViewCriteria(names: ["nobody"])))
        #expect(p.state == .noMatches)
    }

    // MARK: Search

    @Test func searchAcceptsPatternsAndFolders() {
        #expect(Set(ids(nil, query: "jevdump")) == ["w1"])
        #expect(ids(nil, query: "/^pog-/") == ["n1"])
        #expect(Set(ids(nil, query: "worker-*")) == ["w1", "w2"])
        #expect(AgentListBuilder.presentation(snapshot: snapshot, query: "/[/", frecency: [:], now: F.now).state == .noMatches)
        #expect(ids(view(AgentViewCriteria(projects: ["AptusFit"])), query: "worker") == ["w2"])
    }

    @Test func searchSentinelIsPlainText() {
        #expect(ids(nil, query: "$(echo INJECTED)").isEmpty)
    }

    // MARK: Grouping

    @Test func groupByProjectSortsNamesAndPutsNoProjectLast() {
        let rows = AgentListBuilder.presentation(snapshot: snapshot, query: "", frecency: [:], now: F.now, view: view(groupBy: .project)).rows
        #expect(rows.map(\.id) == [
            "group-project-AptusFit", "agent-n1", "agent-w2",
            "group-project-Parklet", "agent-w1",
            "group-project-none", "agent-p1"
        ])
    }

    @Test func groupByStatusIsFlatSections() {
        let rows = AgentListBuilder.presentation(snapshot: snapshot, query: "", frecency: [:], now: F.now, view: view(groupBy: .status)).rows
        #expect(rows.first?.id == "section-0")
        #expect(rows.contains { $0.id == "section-2" })
    }

    @Test func groupByLastActiveUsesDayBuckets() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let agents = snapshot.agents
        let rows = AgentViewGrouping.rows(for: agents, groupBy: .lastActive, tree: nil, isSearching: false, frecency: [:], now: F.now, calendar: calendar)
        let headers = rows.compactMap { row -> String? in
            if case .groupHeader(_, let title) = row { return title }
            return nil
        }
        #expect(headers.last == "Unknown")
        #expect(rows.firstIndex { $0.id == "agent-n1" }! < rows.firstIndex { $0.id == "agent-w2" }!)
    }

    // MARK: Storage

    @Test func storeRoundTripsUnderItsKey() throws {
        let d = defaults()
        let store = AgentSavedViewStore(defaults: d)
        let saved = AgentSavedView(name: "Aptus", keywords: "x", groupBy: .project,
                                   criteria: AgentViewCriteria(names: ["pog-*"], projects: ["AptusFit"], sections: [.working, .needsYou], activeWithinMinutes: 60))
        store.add(saved)
        #expect(d.data(forKey: "AgentBar.savedViews.v1") != nil)
        #expect(AgentSavedViewStore(defaults: d).views == [saved])
    }

    @Test func decodingIsLenientAndFlat() throws {
        let json = """
        [{"id":"6F1C1B44-1C2A-4F7E-9C51-2B9E2B0B7C11","name":"A","groupBy":"bogus","names":["POG-*","/[/"],
          "sections":["working","nope"],"activeWithinMinutes":-5,"future":1},
         "garbage"]
        """
        let views = AgentSavedViewStore.decodeLossy(Data(json.utf8))
        #expect(views.count == 1)
        let v = try #require(views.first)
        #expect(v.groupBy == .none)
        #expect(v.criteria.names == ["pog-*"])
        #expect(v.criteria.sections == [.working])
        #expect(v.criteria.activeWithinMinutes == nil)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(v)) as? [String: Any]
        #expect(encoded?["names"] != nil && encoded?["name"] as? String == "A")
    }

    // MARK: Pages

    @Test func pagesSwitchByNumberAndStep() {
        let pages = AgentPagesModel(store: AgentSavedViewStore(defaults: defaults()))
        var changes = 0
        pages.onPageChange = { changes += 1 }
        let a = AgentSavedView(name: "A"), b = AgentSavedView(name: "B")
        pages.store.add(a)
        pages.store.add(b)
        #expect(pages.orderedPages == [.builtin(.all), .custom(a.id), .custom(b.id), .newView])
        #expect(pages.selectNumbered(3))
        #expect(pages.activeView == b)
        #expect(!pages.selectNumbered(4))
        #expect(pages.step(-1))
        #expect(pages.activePage == .custom(a.id))
        #expect(pages.selectNumbered(1))
        #expect(!pages.step(-1))
        #expect(changes == 3)
        #expect(pages.tabs.map(\.shortcutNumber) == [1, 2, 3, nil])
    }

    @Test func newViewEditorSavesAndCancelReturns() throws {
        let pages = AgentPagesModel(store: AgentSavedViewStore(defaults: defaults()))
        pages.select(.newView)
        #expect(pages.editor?.isNew == true)
        #expect(pages.activePage == .newView)
        #expect(!pages.saveEditor())   // no name yet
        pages.cancelEditor()
        #expect(pages.editor == nil && pages.activePage == .builtin(.all))

        pages.beginNew()
        pages.editor?.draft.name = " Workers "
        pages.editor?.draft.namesText = "worker-*, /jev/"
        pages.editor?.draft.sections = [.working]
        #expect(pages.saveEditor())
        let saved = try #require(pages.store.views.first)
        #expect(saved.name == "Workers")
        #expect(saved.criteria.names == ["worker-*", "/jev/"])
        #expect(pages.activePage == .custom(saved.id))
    }

    @Test func brokenPatternBlocksSave() {
        var draft = AgentViewDraft.new()
        draft.name = "x"
        draft.namesText = "/[/"
        #expect(draft.issues == [.brokenPattern("/[/")])
    }

    @Test func deletingTheActiveViewFallsBackToAll() {
        let pages = AgentPagesModel(store: AgentSavedViewStore(defaults: defaults()))
        let a = AgentSavedView(name: "A")
        pages.store.add(a)
        pages.select(.custom(a.id))
        pages.beginEdit(id: a.id, confirmingDelete: true)
        #expect(pages.editor?.isConfirmingDelete == true)
        pages.deleteView(id: a.id)
        #expect(pages.store.views.isEmpty && pages.editor == nil && pages.activePage == .builtin(.all))
    }

    @Test func panelModelFiltersByActivePageAndSelectsFirstRow() {
        let pages = AgentPagesModel(store: AgentSavedViewStore(defaults: defaults()))
        let model = AgentPanelModel(store: FrecencyStore(defaults: defaults()), pages: pages, now: { F.now })
        model.receive(snapshot)
        #expect(model.presentation.agents.count == 4)
        let parklet = AgentSavedView(name: "Parklet", criteria: AgentViewCriteria(projects: ["Parklet"]))
        pages.store.add(parklet)
        pages.select(.custom(parklet.id))
        #expect(model.presentation.agents.map(\.id) == ["w1"])
        #expect(model.selectedAgentID == "w1")
        #expect(model.agentCount(in: parklet) == 1)
        #expect(model.canSwitchPages)
        pages.beginNew()
        #expect(!model.canSwitchPages)
    }

    @Test func flickStepsOncePerGesture() {
        var flick = AgentPageFlickDetector()
        #expect(flick.handleScroll(deltaX: -40, deltaY: 0, isEnded: false, isMomentum: false) == nil)
        #expect(flick.handleScroll(deltaX: -40, deltaY: 0, isEnded: false, isMomentum: false) == 1)
        #expect(flick.handleScroll(deltaX: -80, deltaY: 0, isEnded: false, isMomentum: false) == nil)
        _ = flick.handleScroll(deltaX: 0, deltaY: 0, isEnded: true, isMomentum: false)
        #expect(flick.handleScroll(deltaX: 10, deltaY: 50, isEnded: false, isMomentum: false) == nil)
        #expect(flick.handleScroll(deltaX: 70, deltaY: 0, isEnded: false, isMomentum: false) == -1)
    }

    @Test func pageStripAddsItsHeight() {
        let p = AgentListPresentation(state: .noAgents, rows: [], showsBoardNote: false)
        #expect(AgentPanelMetrics.height(for: p, showsPageStrip: true) - AgentPanelMetrics.height(for: p) == AgentPanelMetrics.pageStripHeight)
    }
    // MARK: Zero views: no strip

    @Test func stripAndPageKeysOnlyOnceAViewExists() {
        let pages = AgentPagesModel(store: AgentSavedViewStore(defaults: defaults()))
        let model = AgentPanelModel(store: FrecencyStore(defaults: defaults()), pages: pages, now: { F.now })
        model.receive(snapshot)
        #expect(!model.showsPageStrip)
        #expect(!model.canSwitchPages)
        #expect(!pages.selectNumbered(1))
        #expect(!pages.step(1))
        #expect(pages.activePage == .builtin(.all))
        let a = AgentSavedView(name: "A")
        pages.store.add(a)
        #expect(model.showsPageStrip && model.canSwitchPages)
        pages.select(.custom(a.id))
        pages.deleteView(id: a.id)
        #expect(!model.showsPageStrip && pages.activePage == .builtin(.all))
    }

    @Test func viewCommandOpensTheEditorWithoutAStrip() throws {
        let pages = AgentPagesModel(store: AgentSavedViewStore(defaults: defaults()))
        let model = AgentPanelModel(store: FrecencyStore(defaults: defaults()), pages: pages, now: { F.now })
        model.receive(snapshot)
        #expect(AgentPagesModel.isNewViewCommand("  /VIEW "))
        #expect(!AgentPagesModel.isNewViewCommand("/views"))
        model.query = "/view"
        model.activateSelected()
        #expect(pages.editor?.isNew == true)
        #expect(model.query.isEmpty)
        #expect(!model.showsPageStrip)
        pages.editor?.draft.name = "First"
        #expect(pages.saveEditor())
        #expect(model.showsPageStrip)
        let first = try #require(pages.store.views.first)
        #expect(pages.activePage == .custom(first.id))
    }

    @Test func zeroViewHeightMatchesMain() {
        let pages = AgentPagesModel(store: AgentSavedViewStore(defaults: defaults()))
        let model = AgentPanelModel(store: FrecencyStore(defaults: defaults()), pages: pages, now: { F.now })
        model.receive(snapshot)
        let withStripFlag = AgentPanelMetrics.height(for: model.presentation, showsPageStrip: model.showsPageStrip)
        #expect(withStripFlag == AgentPanelMetrics.height(for: model.presentation))
    }
}
