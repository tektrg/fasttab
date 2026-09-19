import Foundation
import Testing
@testable import AgentBar

struct AgentListBuilderTests {
    typealias F = AgentListFixtures

    private let mixed = F.snapshot([
        F.agent("a1", section: .needsYou),
        F.agent("a2", section: .working),
        F.agent("a3", section: .parked),
        F.agent("a4", section: .ended)
    ])

    @Test func groupsUnderHeadersInSectionOrder() {
        let rows = F.presentation(mixed).rows
        #expect(rows.map(\.id) == [
            "section-0", "agent-a1", "section-1", "agent-a2", "section-2", "agent-a3", "section-3", "agent-a4"
        ])
    }

    @Test func emptySectionsGetNoHeader() {
        let snapshot = F.snapshot([F.agent("w", section: .working), F.agent("e", section: .ended)])
        #expect(F.presentation(snapshot).rows.map(\.id) == ["section-1", "agent-w", "section-3", "agent-e"])
    }

    @Test func endedRowsAreShownButNotSelectable() {
        #expect(F.presentation(mixed).selectableAgentIDs == ["a1", "a2", "a3"])
    }

    // MARK: State selection

    @Test func noSnapshotYetIsConnecting() {
        #expect(F.presentation(nil).state == .connecting)
    }

    @Test func downFeedIsNeverAnEmptyList() {
        let down = F.snapshot([], health: .down(reason: "Can't reach the dashboard."), boardIsCurrent: false)
        let presentation = F.presentation(down)
        #expect(presentation.state == .feedDown(reason: "Can't reach the dashboard."))
        #expect(presentation.rows.isEmpty)
        #expect(!presentation.showsBoardNote)
    }

    @Test func healthyWithZeroAgentsIsNoAgents() {
        #expect(F.presentation(F.snapshot([])).state == .noAgents)
    }

    @Test func queryExcludingEveryoneIsNoMatches() {
        #expect(F.presentation(mixed, query: "zzzz").state == .noMatches)
    }

    @Test func staleBoardShowsNoteOnHealthyStates() {
        let stale = F.snapshot([F.agent("a")], boardIsCurrent: false)
        #expect(F.presentation(stale).showsBoardNote)
        #expect(F.presentation(stale, query: "zzzz").showsBoardNote)
        #expect(F.presentation(F.snapshot([], boardIsCurrent: false)).showsBoardNote)
        #expect(!F.presentation(mixed).showsBoardNote)
    }

    // MARK: Search

    private let searchable = F.snapshot([
        F.agent("1", label: "Billing", project: "Café-Web", statusText: "reading", excerpt: "Should we migrate the invoices table?"),
        F.agent("2", label: "Docs", project: "site", statusText: "Đơn hàng review"),
        F.agent("3", label: "Infra", project: "cafe-api", statusText: "idle")
    ])

    private func matchedIDs(_ query: String) -> [String] {
        F.presentation(searchable, query: query).agents.map(\.id)
    }

    @Test func blankQueryKeepsEveryone() {
        #expect(matchedIDs("").count == 3)
        #expect(matchedIDs("   ").count == 3)
    }

    @Test func matchesLabelProjectExcerptAndStatusText() {
        #expect(matchedIDs("billing") == ["1"])
        #expect(matchedIDs("site") == ["2"])
        #expect(matchedIDs("invoices") == ["1"])
        #expect(matchedIDs("reading") == ["1"])
    }

    @Test func foldsAccentsAndCase() {
        #expect(matchedIDs("CAFE") == ["1", "3"])
        #expect(matchedIDs("don hang") == ["2"])
    }

    @Test func everyWordMustMatchAcrossFields() {
        #expect(matchedIDs("cafe billing") == ["1"])
        #expect(matchedIDs("cafe docs") == [])
    }

    @Test func sectionsStayGroupedWhileFilteringAndEmptyOnesVanish() {
        let snapshot = F.snapshot([
            F.agent("x1", label: "alpha", section: .needsYou),
            F.agent("x2", label: "beta", section: .working),
            F.agent("x3", label: "alpha two", section: .parked)
        ])
        let rows = F.presentation(snapshot, query: "alpha").rows
        #expect(rows.map(\.id) == ["section-0", "agent-x1", "section-2", "agent-x3"])
    }

    // MARK: - Needs you / Working / Parked / Ended

    @Test func sectionOrderIsNeedsYouWorkingParkedEnded() {
        let snapshot = F.snapshot([
            F.agent("e", section: .ended), F.agent("p", section: .parked),
            F.agent("w", section: .working), F.agent("n", section: .needsYou)
        ])
        #expect(F.presentation(snapshot).agents.map(\.id) == ["n", "w", "p", "e"])
        #expect(F.presentation(snapshot).rows.compactMap { row -> String? in
            if case .header(let section) = row { return section.title }
            return nil
        } == ["Needs you", "Working", "Parked", "Ended"])
    }

    @Test func parkedAgentsAreAppliedFromTheTriageStateBelowWorking() {
        var triage = TriageState.empty
        triage.park("n2")
        let snapshot = F.snapshot([F.agent("n1", section: .needsYou), F.agent("n2", section: .needsYou), F.agent("w", section: .working)])
        let presentation = AgentListBuilder.presentation(
            snapshot: snapshot, query: "", frecency: [:], now: F.now, settings: .standard, triage: triage
        )
        #expect(presentation.agents.map(\.id) == ["n1", "w", "n2"])
        #expect(presentation.agents.last?.section == .parked)
    }

    @Test func searchReachesParkedAgentsToo() {
        var triage = TriageState.empty
        triage.park("p1")
        let snapshot = F.snapshot([
            F.agent("p1", label: "billing fix", section: .needsYou), F.agent("n1", label: "docs", section: .needsYou)
        ])
        let presentation = AgentListBuilder.presentation(
            snapshot: snapshot, query: "billing", frecency: [:], now: F.now, settings: .standard, triage: triage
        )
        #expect(presentation.rows.map(\.id) == ["section-2", "agent-p1"])
    }
}
