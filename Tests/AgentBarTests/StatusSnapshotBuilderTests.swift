import Foundation
import Testing
@testable import AgentBar

struct StatusSnapshotBuilderTests {
    private let healthy = try! StatusFixtures.snapshot("state-healthy")

    @Test func healthyFixtureIsOkAndSkipsResidue() {
        #expect(healthy.health == .ok)
        #expect(healthy.boardIsCurrent)
        #expect(healthy.fetchedAt == StatusFixtures.serverNow)
        // 9 fixture agents, one is residue (a dead pane's leftover hook file).
        #expect(healthy.agents.filter { $0.section != .ended }.count == 8)
        #expect(healthy.agent(labelled: "(no matching herdr pane)") == nil)
    }

    @Test func liveAgentsLandInTheRightSectionsInDisplayOrder() {
        func labels(_ section: AgentSection) -> [String] { healthy.agents(in: section).map(\.label) }
        // Real prompts first, then agents that merely finished, server order kept.
        #expect(labels(.needsYou) == ["agent-one", "agent-two", "agent-four", "agent-five", "shell-one"])
        #expect(labels(.working) == ["agent-three", "agent-six", "agent-seven"])
        #expect(labels(.parked).isEmpty)   // parking is the user's, never the feed's
        #expect(healthy.agents.map(\.section) == healthy.agents.map(\.section).sorted())
    }

    @Test func needsYouComesFromDashboardListAndFromScreenState() throws {
        let questionRow = try #require(healthy.agent(labelled: "agent-one"))
        let permissionRow = try #require(healthy.agent(labelled: "agent-two"))
        #expect(questionRow.section == .needsYou)
        #expect(permissionRow.section == .needsYou)

        // Drop the dashboard's needsYou list: the NEEDS_HUMAN screen alone still flags both.
        let withoutList = try StatusSnapshotBuilder.snapshot(
            fromJSON: StatusFixtures.data("state-healthy") { object in
                var computed = object["computed"] as! [String: Any]
                computed["needsYou"] = [Any]()
                object["computed"] = computed
            },
            fetchedAt: StatusFixtures.serverNow
        )
        #expect(withoutList.agents(in: .needsYou).map(\.label).prefix(2) == ["agent-one", "agent-two"])
    }

    @Test func dashboardNeedsYouEntryFlagsAnAgentWhoseScreenIsUnreadable() throws {
        let snapshot = try StatusSnapshotBuilder.snapshot(
            fromJSON: StatusFixtures.data("state-healthy") { object in
                var computed = object["computed"] as! [String: Any]
                var agents = computed["agents"] as! [[String: Any]]
                agents[4]["screenState"] = NSNull()   // agent-five: hook blocked, screen unknown
                computed["agents"] = agents
                computed["needsYou"] = (computed["needsYou"] as! [Any]) + [
                    ["kind": "blocked", "urgency": 1, "label": "agent-five", "paneId": "w1:p5", "detail": "unconfirmed", "sinceSec": 60.0]
                ]
                object["computed"] = computed
            },
            fetchedAt: StatusFixtures.serverNow
        )
        #expect(snapshot.agent(labelled: "agent-five")?.section == .needsYou)
        #expect(snapshot.agent(labelled: "agent-five")?.secondsInStatus == 60.0)
    }

    @Test func finishedAgentWithoutAPromptIsStillNeedsYouButNotFirst() throws {
        // hook says blocked, screen says waiting: no real prompt, yet not working either.
        let finished = try #require(healthy.agent(labelled: "agent-five"))
        #expect(finished.section == .needsYou)
        let needsYouLabels = healthy.agents(in: .needsYou).map(\.label)
        let finishedIndex = try #require(needsYouLabels.firstIndex(of: "agent-five"))
        let promptIndex = try #require(needsYouLabels.firstIndex(of: "agent-two"))
        #expect(finishedIndex > promptIndex)
    }

    @Test func nonClaudePaneHasNoHookDataAndNeedsYou() throws {
        let shell = try #require(healthy.agent(labelled: "shell-one"))
        #expect(shell.section == .needsYou)
        #expect(!shell.hasHookData)
        #expect(shell.secondsInStatus == nil)
        #expect(shell.id == "w1:p8")   // no session id: falls back to the pane id
    }

    @Test func idIsSessionIdElsePaneId() throws {
        #expect(try #require(healthy.agent(labelled: "agent-one")).id == StatusFixtures.sessionId(1))
    }

    @Test func questionRowShowsTitleAndSearchesOnTheQuestion() throws {
        let row = try #require(healthy.agent(labelled: "agent-one"))
        #expect(row.statusText == "Storage choice")
        #expect(row.promptExcerpt == "Should the sample setting persist to disk per workspace, or stay session-only and reset each time the app reopens?")
        #expect(row.secondsInStatus == 4179.3)
        #expect(row.canFocus)
        #expect(row.paneId == "w1:p1")
    }

    @Test func permissionRowShowsTheScreenPrompt() throws {
        let row = try #require(healthy.agent(labelled: "agent-two"))
        #expect(row.statusText == "Do you want to proceed?")
        #expect(row.promptExcerpt == "Do you want to proceed?")
    }

    @Test func statusTextFallsBackToHookReasonThenSectionName() throws {
        #expect(try #require(healthy.agent(labelled: "agent-five")).statusText == "Claude is waiting for your input")  // signal is a bare prompt glyph
        #expect(try #require(healthy.agent(labelled: "agent-seven")).statusText == "Working")                          // no signal, no reason
        #expect(try #require(healthy.agent(labelled: "agent-three")).statusText.hasPrefix("✶ Working"))
    }

    @Test func projectNameComesFromCwdAndResolvesWorktrees() {
        #expect(healthy.agent(labelled: "agent-one")?.projectName == "sample-app")
        #expect(healthy.agent(labelled: "agent-two")?.projectName == "sample-app")   // .claude/worktrees/feature-x
        #expect(healthy.agent(labelled: "agent-four")?.projectName == "sample-app")  // nested inside a worktree
        #expect(healthy.agent(labelled: "agent-three")?.projectName == "other-tool")
    }

    @Test func unpushedMarkerComesFromTheBoardsLiveRows() throws {
        let ahead = try #require(healthy.agent(labelled: "agent-three"))
        #expect(ahead.hasUnpushedCommits)
        #expect(ahead.unpushedText == "2 ahead — not pushed")
        let neverPushed = try #require(healthy.agent(labelled: "agent-four"))
        #expect(neverPushed.hasUnpushedCommits)
        #expect(neverPushed.unpushedText == "no upstream — never pushed")
        let clean = try #require(healthy.agent(labelled: "agent-one"))
        #expect(!clean.hasUnpushedCommits)
        #expect(clean.unpushedText == nil)
    }

    // MARK: - Ended

    private var endedIds: [String] { healthy.agents(in: .ended).map(\.id) }

    /// What the list shows out of the box: the snapshot's ended rows narrowed to 24h / 8.
    private var endedIdsWithStandardSettings: [String] {
        AgentListSettings.standard.applying(to: healthy.agents).filter { $0.section == .ended }.map(\.id)
    }

    @Test func endedRowsAreNewestFirstAndCappedAtEightByDefault() {
        // Ten rows ended within 24h; the two oldest (by end time) fall off the cap.
        let expected = [2, 7, 4, 9, 1, 6, 10, 3].map { StatusFixtures.sessionId(100 + $0) }
        #expect(endedIdsWithStandardSettings == expected)
        #expect(EndedAgentMapper.maxEndedCount == 8)
    }

    @Test func snapshotCarriesTheDashboardsWholeEndedWindowForTheListToNarrow() {
        // 30h and 60h old rows are outside the default 24h but inside the 72h the dashboard keeps.
        #expect(endedIds.contains(StatusFixtures.sessionId(120)))
        #expect(endedIds.contains(StatusFixtures.sessionId(121)))
        #expect(endedIds.count == 12)
        #expect(EndedAgentMapper.Limits.widest.windowSeconds == 72 * 60 * 60)
    }

    @Test func endedRowsOutsideTheDefaultWindowAreDropped() {
        #expect(!endedIdsWithStandardSettings.contains(StatusFixtures.sessionId(120)))   // ended 30h ago
        #expect(!endedIdsWithStandardSettings.contains(StatusFixtures.sessionId(121)))   // ended 60h ago
        #expect(EndedAgentMapper.endedWindowSeconds == 24 * 60 * 60)
    }

    @Test func archivedAndUnnamedEndedRowsAreDropped() {
        #expect(!endedIds.contains(StatusFixtures.sessionId(122)))   // archived
        #expect(!endedIds.contains("pane:w2-p23"))                   // "(no matching herdr pane)"
        #expect(!endedIds.contains("pane:w2-p24"))                   // label is the raw "pane:..." id
    }

    @Test func endedRowsThatAreStillLiveAreDropped() {
        #expect(!endedIds.contains("pane:w1-p3"))                    // same pane as live agent-three
        #expect(!endedIds.contains(StatusFixtures.sessionId(126)))   // same session as live agent-three
    }

    @Test func endedRowsCannotBeFocusedAndCarryTheirAge() throws {
        let newest = try #require(healthy.agents(in: .ended).first)
        #expect(newest.label == "ended-agent-2")
        #expect(!newest.canFocus)
        #expect(newest.secondsInStatus == 300)
        #expect(newest.statusText == "ended")
        #expect(!newest.hasUnpushedCommits)
    }

    @Test func staleBoardDegradesGracefullyWithoutGoingDown() throws {
        let snapshot = try StatusFixtures.snapshot("state-board-stale")
        #expect(snapshot.health == .ok)
        #expect(!snapshot.boardIsCurrent)
        #expect(snapshot.agents(in: .ended).isEmpty)
        #expect(snapshot.agents.allSatisfy { !$0.hasUnpushedCommits })
        #expect(snapshot.agents(in: .needsYou).count == 5)   // live statuses are unaffected
        #expect(snapshot.agents(in: .working).count == 3)
    }
}
