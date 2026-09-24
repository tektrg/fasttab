import Foundation
import CommandBarKit
@testable import AgentBar

/// Hand-built agents and snapshots for list logic tests.
enum AgentListFixtures {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func agent(
        _ id: String,
        label: String? = nil,
        project: String? = nil,
        section: AgentSection = .needsYou,
        statusText: String = "waiting",
        excerpt: String? = nil,
        canFocus: Bool? = nil,
        hasHookData: Bool = true,
        secondsInStatus: TimeInterval? = 120,
        actions: AgentActions = .unknown,
        paneId: String? = nil
    ) -> AgentSnapshot {
        AgentSnapshot(
            id: id,
            label: label ?? id,
            projectName: project,
            cwd: nil,
            paneId: paneId ?? "w1:\(id)",
            section: section,
            statusText: statusText,
            secondsInStatus: secondsInStatus,
            hasUnpushedCommits: false,
            unpushedText: nil,
            promptExcerpt: excerpt,
            canFocus: canFocus ?? (section != .ended),
            hasHookData: hasHookData,
            rowId: id,
            actions: section == .working ? .none : actions
        )
    }

    static func snapshot(
        _ agents: [AgentSnapshot],
        health: StatusFeedHealth = .ok,
        boardIsCurrent: Bool = true,
        agentTree: AgentTree? = nil
    ) -> StatusSnapshot {
        StatusSnapshot(agents: agents, health: health, fetchedAt: now, boardIsCurrent: boardIsCurrent, agentTree: agentTree)
    }

    static func presentation(
        _ snapshot: StatusSnapshot?,
        query: String = "",
        frecency: [String: FrecencyEntry] = [:],
        settings: AgentListSettings = .standard
    ) -> AgentListPresentation {
        AgentListBuilder.presentation(snapshot: snapshot, query: query, frecency: frecency, now: now, settings: settings)
    }
}
