import Foundation
import Testing
@testable import AgentBar

/// Sleeping Claude Desktop sessions (`computed.sleepingSessions`, dashboard `desktop_sessions.py`):
/// the "Sleeping" section, its list/search day windows, and what a sleeping row can do.
enum SleepingFixtures {
    static let serverNow: TimeInterval = 1_790_000_000
    static let day: TimeInterval = 86_400

    static func entry(_ key: String, daysAgo: Double, label: String? = nil, cli: Bool = true) -> String {
        let cliField = cli ? "\"cli-\(key)\"" : "null"
        let labelField = label.map { "\"\($0)\"" } ?? "null"
        return """
        {"desktopSessionId": "local_\(key)", "cliSessionId": \(cliField), "label": \(labelField),
         "cwd": "/Users/me/01_Project/\(key)-repo", "lastActiveTs": \(serverNow - daysAgo * day),
         "openUrl": "claude://code/continue?session=local_\(key)"}
        """
    }

    static func snapshot(sleeping: [String], agents: [String] = []) throws -> StatusSnapshot {
        let json = """
        {"serverTimeTs": \(serverNow), \(StatusOnlyFixtures.feeds),
         "computed": {"agents": [\(agents.joined(separator: ","))], "needsYou": [],
                      "sleepingSessions": [\(sleeping.joined(separator: ","))]}}
        """
        return try StatusSnapshotBuilder.snapshot(fromJSON: Data(json.utf8), fetchedAt: Date(timeIntervalSince1970: serverNow))
    }

    static func presentation(_ snapshot: StatusSnapshot, query: String = "", settings: AgentListSettings = .standard) -> AgentListPresentation {
        AgentListBuilder.presentation(
            snapshot: snapshot, query: query, frecency: [:], now: Date(timeIntervalSince1970: serverNow), settings: settings
        )
    }
}

struct SleepingSessionMapperTests {
    typealias S = SleepingFixtures

    @Test func aSleepingSessionIsAGreyedDesktopRowKeyedByItsClaudeSession() throws {
        let snapshot = try S.snapshot(sleeping: [S.entry("aaa", daysAgo: 2, label: "Robust search feature")])
        let row = try #require(snapshot.agents.first)
        #expect(row.id == "cli-aaa")                  // same id as the live row it becomes when woken
        #expect(row.sessionId == "cli-aaa")           // Space shows its latest message
        #expect(row.section == .sleeping)
        #expect(row.label == "Robust search feature")
        #expect(row.projectName == "aaa-repo")
        #expect(row.statusText == "Sleeping · 2d ago")
        #expect(row.secondsInStatus == 2 * S.day)
        #expect(row.host == .claudeDesktop(openURL: URL(string: "claude://code/continue?session=local_aaa")))
        #expect(row.paneId == nil && row.rowId == nil && row.blocker == nil && row.actions == .none)
        #expect(row.canFocus)
    }

    @Test func withoutAClaudeSessionIdTheDesktopIdIsTheIdentity() throws {
        let row = try #require(try S.snapshot(sleeping: [S.entry("bbb", daysAgo: 1, cli: false)]).agents.first)
        #expect(row.id == "local_bbb")
        #expect(row.sessionId == nil)
        #expect(row.label == "bbb-repo")              // no title: folder name
    }

    @Test func sleepingRowsComeAfterLiveOnesNewestFirst() throws {
        let snapshot = try S.snapshot(
            sleeping: [S.entry("old", daysAgo: 3), S.entry("new", daysAgo: 0.5)],
            agents: [StatusOnlyFixtures.desktopRow(status: "busy", hookState: "working")]
        )
        #expect(snapshot.agents.map(\.id) == [StatusOnlyFixtures.desktopSession, "cli-new", "cli-old"])
    }

    @Test func aBadEntryCostsOnlyItselfAndAnOlderDashboardHasNone() throws {
        let snapshot = try S.snapshot(sleeping: ["{\"label\": 5}", "42", S.entry("ok", daysAgo: 1)])
        #expect(snapshot.agents.map(\.id) == ["cli-ok"])
        let older = try StatusOnlyFixtures.snapshot(agents: [])
        #expect(older.agents.isEmpty)
    }

    @Test func aForeignOpenUrlIsNeverKept() throws {
        let entry = S.entry("evil", daysAgo: 1).replacingOccurrences(of: "claude://code/continue?session=local_evil", with: "https://example.com")
        let row = try #require(try S.snapshot(sleeping: [entry]).agents.first)
        #expect(row.host == .claudeDesktop(openURL: nil))   // Enter then only activates Claude.app
    }

    @Test func oneClaudeSessionInTwoDesktopProfilesIsOneRowTheNewest() throws {
        let older = S.entry("shared", daysAgo: 2, label: "Older profile")
        let newer = S.entry("shared", daysAgo: 1, label: "Newer profile").replacingOccurrences(of: "local_shared", with: "local_other")
        let snapshot = try S.snapshot(sleeping: [older, newer])
        #expect(snapshot.agents.map(\.id) == ["cli-shared"])
        #expect(snapshot.agents.first?.label == "Newer profile")
    }
}

struct SleepingSessionListTests {
    typealias S = SleepingFixtures

    private func ids(_ presentation: AgentListPresentation) -> [String] { presentation.agents.map(\.id) }

    @Test func defaultsAreThreeDaysListedAndSevenDaysSearched() {
        let settings = AgentListSettings.load(from: makeScratchDefaults())
        #expect(settings.sleepingListDays == 3)
        #expect(settings.sleepingSearchDays == 7)
    }

    @Test func daySettingsRoundTripAndBadValuesFallBack() {
        let defaults = makeScratchDefaults()
        var chosen = AgentListSettings.standard
        chosen.sleepingListDays = 0
        chosen.sleepingSearchDays = 14
        chosen.save(to: defaults)
        #expect(AgentListSettings.load(from: defaults) == chosen)
        defaults.set(4, forKey: AgentListSettings.sleepingListDaysKey)      // not a choice
        defaults.set(0, forKey: AgentListSettings.sleepingSearchDaysKey)    // 0 is list-only
        let loaded = AgentListSettings.load(from: defaults)
        #expect(loaded.sleepingListDays == 3 && loaded.sleepingSearchDays == 7)
    }

    @Test func theListShowsListDaysUnderTheirOwnHeaderAndSearchReachesSearchDays() throws {
        let snapshot = try S.snapshot(sleeping: [
            S.entry("fresh", daysAgo: 1, label: "Fresh repo work"), S.entry("five", daysAgo: 5, label: "Five day repo work"),
            S.entry("ten", daysAgo: 10, label: "Ten day repo work"),
        ])
        let listed = S.presentation(snapshot)
        #expect(ids(listed) == ["cli-fresh"])
        #expect(listed.rows.first == .header(.sleeping))
        #expect(ids(S.presentation(snapshot, query: "repo")) == ["cli-fresh", "cli-five"])
        #expect(ids(S.presentation(snapshot, query: "five-repo")) == ["cli-five"])   // folder matches too
        #expect(ids(S.presentation(snapshot, query: "ten")).isEmpty)
    }

    @Test func aSleepingRowsAgeIsNotSearchableButTheWordSleepingIs() throws {
        let snapshot = try S.snapshot(sleeping: [S.entry("aaa", daysAgo: 2, label: "Fix login")])
        #expect(ids(S.presentation(snapshot, query: "ago")).isEmpty)
        #expect(ids(S.presentation(snapshot, query: "2d")).isEmpty)
        #expect(ids(S.presentation(snapshot, query: "sleeping")) == ["cli-aaa"])
        #expect(ids(S.presentation(snapshot, query: "login")) == ["cli-aaa"])
    }

    @Test func searchNeverNarrowsBelowTheListWindowAndZeroListDaysIsSearchOnly() throws {
        let snapshot = try S.snapshot(sleeping: [S.entry("five", daysAgo: 5, label: "work")])
        var settings = AgentListSettings.standard
        settings.sleepingListDays = 7
        settings.sleepingSearchDays = 1
        #expect(ids(S.presentation(snapshot, query: "work", settings: settings)) == ["cli-five"])
        settings.sleepingListDays = 0
        settings.sleepingSearchDays = 7
        #expect(S.presentation(snapshot, settings: settings).state == .noAgents)
        #expect(ids(S.presentation(snapshot, query: "work", settings: settings)) == ["cli-five"])
        // A last-activity stamp at (or past) the server's now is still search-only at 0 days.
        let justNow = try S.snapshot(sleeping: [S.entry("now", daysAgo: -0.01, label: "work")])
        #expect(S.presentation(justNow, settings: settings).state == .noAgents)
    }

    @Test func hidingClaudeOutsideHerdrHidesSleepingSessionsToo() throws {
        let snapshot = try S.snapshot(sleeping: [S.entry("aaa", daysAgo: 1)])
        var settings = AgentListSettings.standard
        settings.showsClaudeOutsideHerdr = false
        #expect(ids(S.presentation(snapshot, query: "aaa", settings: settings)).isEmpty)
    }

    @Test func aSleepingRowOffersOnlyOpenInClaudeAndIsNeverParked() throws {
        let row = try #require(try S.snapshot(sleeping: [S.entry("aaa", daysAgo: 1)]).agents.first)
        #expect(RowButtons.available(for: row).map(\.button) == [.openInClaude])
        #expect(RowButtons.menuItems(for: row).isEmpty)
        #expect(!RowButtons.isPressable(.message, on: row))
        var triage = TriageState(parkedIDs: [row.id])
        triage.observe([row])
        #expect(!triage.isParked(row.id))              // not live: forgotten like an ended row
    }
}

/// Open in Claude on a sleeping row does exactly what Enter does: `onActivate` (the host wakes it
/// in Claude.app via its `claude://code/continue` link).
@MainActor
struct SleepingOpenInClaudeTests {
    typealias S = SleepingFixtures

    @Test func pressingOpenInClaudeActivatesTheSleepingRowLikeEnter() throws {
        let defaults = makeScratchDefaults("sleeping-open-\(UUID().uuidString)")
        let model = AgentPanelModel(
            store: FrecencyStore(defaults: defaults),
            triageStore: TriageStore(defaults: defaults),
            routedNoteStore: RoutedNoteStore(defaults: defaults),
            now: { Date(timeIntervalSince1970: S.serverNow) }
        )
        var activated: [AgentSnapshot] = []
        model.onActivate = { activated.append($0) }
        model.receive(try S.snapshot(sleeping: [S.entry("aaa", daysAgo: 1)]))
        #expect(model.presentation.agents.map(\.id) == ["cli-aaa"])
        #expect(model.press(.openInClaude, on: "cli-aaa") == nil)
        #expect(activated.map(\.id) == ["cli-aaa"])
        #expect(activated.first?.host == .claudeDesktop(openURL: URL(string: "claude://code/continue?session=local_aaa")))
    }
}

/// A sleeping row is greyed, except the selected (hovered/keyboard) one, so its Open in Claude
/// button doesn't read as disabled. Other greyed kinds keep their shade whether selected or not.
struct SleepingRowDimmingTests {
    typealias S = SleepingFixtures
    typealias F = AgentListFixtures

    @Test func onlyTheSelectedSleepingRowDrawsAtFullOpacity() throws {
        let row = try #require(try S.snapshot(sleeping: [S.entry("aaa", daysAgo: 1)]).agents.first)
        #expect(AgentRowView.dimming(of: row, isSelected: false) == 0.55)
        #expect(AgentRowView.dimming(of: row, isSelected: true) == 1)
    }

    @Test func otherGreyedRowsKeepTheirShadeWhenSelected() {
        let guessed = F.agent("g", section: .working, hasHookData: false)
        let ended = F.agent("e", section: .ended)
        for isSelected in [false, true] {
            #expect(AgentRowView.dimming(of: guessed, isSelected: isSelected) == 0.7)
            #expect(AgentRowView.dimming(of: ended, isSelected: isSelected) == AgentRowView.dimming(of: ended, isSelected: false))
        }
        #expect(AgentRowView.dimming(of: F.agent("w", section: .working), isSelected: false) == 1)   // a woken row is not greyed
    }
}
