import Foundation

/// Turns one dashboard payload (`/api/state` body or SSE event) into a
/// `StatusSnapshot`. Pure: no I/O, no clock beyond the timestamps passed in.
enum StatusSnapshotBuilder {
    /// Throws only when `data` is not a JSON object at all.
    static func snapshot(fromJSON data: Data, fetchedAt: Date) throws -> StatusSnapshot {
        let payload = try JSONDecoder().decode(DashboardPayload.self, from: data)
        return snapshot(from: payload, fetchedAt: fetchedAt)
    }

    static func snapshot(from payload: DashboardPayload, fetchedAt: Date) -> StatusSnapshot {
        if let problem = FeedHealthEvaluator.firstProblem(in: payload.feeds, unreadable: payload.unreadableFeedNames) {
            return .down(reason: "Status feed down: \(problem)", at: fetchedAt)
        }
        let boardIsCurrent = FeedHealthEvaluator.boardIsCurrent(in: payload.feeds)
        let boardRows = boardIsCurrent ? (payload.boardRows ?? []) : []
        let liveAgents = LiveAgentMapper.map(
            agents: payload.agents,
            needsYou: payload.needsYou,
            board: BoardIndex(rows: boardRows)
        )
        // Payload timestamps (ended-at, ages) are on the server's clock.
        let serverNow = payload.serverTimeTs ?? fetchedAt.timeIntervalSince1970
        let ended = EndedAgentMapper.map(
            rows: boardRows,
            liveAgents: liveAgents,
            liveRowIds: Set(payload.agents.compactMap(\.rowId)),
            serverNow: serverNow,
            limits: .widest   // the list narrows it to the user's window and count
        )
        let sleeping = SleepingSessionMapper.map(payload.sleepingSessions, serverNow: serverNow)
        return StatusSnapshot(
            agents: uniqueByID(liveAgents + ended + sleeping),
            health: .ok,
            fetchedAt: fetchedAt,
            boardIsCurrent: boardIsCurrent && payload.boardRows != nil,
            agentTree: AgentTreeMapper.map(payload.agentTree)
        )
    }

    /// One agent per id, the first kept (live before ended before sleeping). A live agent's id is its
    /// Claude session id, so one session in two panes, or a session both live and still listed as
    /// sleeping, would otherwise give two rows one id — which hung the list's `LazyVStack` at 100% CPU
    /// (2026-11-24). Selection and frecency are keyed by id too.
    static func uniqueByID(_ agents: [AgentSnapshot]) -> [AgentSnapshot] {
        var seen = Set<String>()
        return agents.filter { seen.insert($0.id).inserted }
    }
}
