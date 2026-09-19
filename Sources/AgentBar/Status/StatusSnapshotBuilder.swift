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
        return StatusSnapshot(
            agents: liveAgents + ended,
            health: .ok,
            fetchedAt: fetchedAt,
            boardIsCurrent: boardIsCurrent && payload.boardRows != nil
        )
    }
}
