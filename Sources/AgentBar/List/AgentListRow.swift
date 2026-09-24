import Foundation

/// A row's place in the grouped (non-search) hierarchy display — see `AgentListGrouping`. `.flat`
/// is every row exactly as before (Needs you, and the whole list while searching or before the
/// tree has loaded): no indent, no decoration.
enum AgentRowNesting: Equatable {
    case flat
    /// A chief row, heading its own group. `needsYouHint` counts children currently shown only in
    /// Needs you (the dedupe rule: a blocked worker appears there, not nested here too) — > 0 draws
    /// a small "N needs you" hint on the chief's row so that isn't silently invisible. `machineBadge`
    /// mirrors `AgentTreeNode.machineBadge` ("Air" tag rule carried over from the old tree view).
    case chief(needsYouHint: Int, machineBadge: String?)
    /// A worker nested one level under its chief.
    case child(crossProject: Bool, machineBadge: String?)
    /// A row in the Unassigned group: flat, never indented. `lostParentLabel` set only for a
    /// `AgentTree.parentGone` entry (its chief died) — annotated with who it used to report to.
    case unassigned(lostParentLabel: String?, machineBadge: String?)
}

/// A project (or "Unassigned") header in the grouped area.
struct AgentGroupHeader: Equatable, Identifiable {
    enum Kind: Equatable {
        case project(String)
        case unassigned
    }

    let kind: Kind

    var id: String {
        switch kind {
        case .project(let project): "project-\(project)"
        case .unassigned: "unassigned"
        }
    }

    var title: String {
        switch kind {
        case .project(let project): project.isEmpty ? "UNASSIGNED PROJECT" : project.uppercased()
        case .unassigned: "UNASSIGNED"
        }
    }
}

/// One line of the switcher list: a section header, a group header, or an agent.
enum AgentListRow: Equatable, Identifiable {
    case header(AgentSection)
    case groupHeader(AgentGroupHeader)
    case agent(AgentSnapshot, nesting: AgentRowNesting)

    var id: String {
        switch self {
        case .header(let section): "section-\(section.rawValue)"
        case .groupHeader(let header): "group-\(header.id)"
        case .agent(let agent, _): "agent-\(agent.id)"
        }
    }

    /// The agent id when this row can be selected and activated. Headers and
    /// unfocusable rows (ended sessions, anything without a live pane) are
    /// skipped by arrow keys and ignore clicks.
    var selectableAgentID: String? {
        guard case .agent(let agent, _) = self, agent.canFocus else { return nil }
        return agent.id
    }
}

/// What the panel body shows. The states are mutually exclusive and ordered by
/// priority: a dead feed must never be mistaken for an empty list.
enum AgentListState: Equatable {
    /// No snapshot has arrived yet.
    case connecting
    case feedDown(reason: String)
    /// Healthy feed, genuinely zero agents.
    case noAgents
    /// Agents exist but the search query excludes all of them.
    case noMatches
    case list
}

/// Everything the panel view needs to render, derived purely from the latest
/// snapshot + the search text + frecency.
struct AgentListPresentation: Equatable {
    let state: AgentListState
    /// Headers and agents in display order; empty unless `state == .list`.
    let rows: [AgentListRow]
    /// True when the slow delivery-board feed is stale: Ended rows and
    /// unpushed markers are then missing rather than "none".
    let showsBoardNote: Bool

    static let connecting = AgentListPresentation(state: .connecting, rows: [], showsBoardNote: false)

    var selectableAgentIDs: [String] {
        rows.compactMap(\.selectableAgentID)
    }

    var agents: [AgentSnapshot] {
        rows.compactMap { row in
            if case .agent(let agent, _) = row { return agent }
            return nil
        }
    }
}
