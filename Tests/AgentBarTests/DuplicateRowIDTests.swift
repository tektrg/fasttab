import Foundation
import Testing
@testable import AgentBar

/// 2026-11-24 hang: the panel's `LazyVStack`/`ForEach` spun at 100% CPU forever. The list had two
/// rows with one id: a live agent's id is its Claude session id, so the same session shown in two
/// panes (or also listed as sleeping) became two `agent-<id>` rows. SwiftUI's lazy stack cannot place
/// rows whose ids collide, and re-ran layout endlessly. Ids must be unique, at the source and at the list.
struct DuplicateRowIDTests {
    private static let sharedSession = "00000000-0000-4000-8000-000000000001"

    private func snapshotWithSharedSession() throws -> StatusSnapshot {
        try StatusSnapshotBuilder.snapshot(
            fromJSON: StatusFixtures.data("state-healthy") { object in
                var computed = object["computed"] as! [String: Any]
                var agents = computed["agents"] as! [[String: Any]]
                agents[1]["agentSession"] = Self.sharedSession   // a second pane on the same Claude session
                computed["agents"] = agents
                computed["sleepingSessions"] = [[
                    "desktopSessionId": "local_x", "cliSessionId": Self.sharedSession, "label": "x",
                    "cwd": "/tmp/x", "lastActiveTs": StatusFixtures.serverNow.timeIntervalSince1970 - 60,
                    "openUrl": "claude://code/continue?session=local_x",
                ]]
                object["computed"] = computed
            },
            fetchedAt: StatusFixtures.serverNow
        )
    }

    @Test func snapshotNeverHoldsTwoAgentsWithOneID() throws {
        let ids = try snapshotWithSharedSession().agents.map(\.id)
        #expect(ids.count == Set(ids).count)
    }

    @Test func presentationRowIDsAreUniqueEvenFromDuplicateAgents() throws {
        let snapshot = try snapshotWithSharedSession()
        let doubled = StatusSnapshot(
            agents: snapshot.agents + snapshot.agents, health: .ok, fetchedAt: snapshot.fetchedAt,
            boardIsCurrent: snapshot.boardIsCurrent, agentTree: snapshot.agentTree
        )
        let rows = AgentListBuilder.presentation(snapshot: doubled, query: "", frecency: [:], now: StatusFixtures.serverNow).rows
        #expect(!rows.isEmpty)
        #expect(rows.map(\.id).count == Set(rows.map(\.id)).count)
    }
}
