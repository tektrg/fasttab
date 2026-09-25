import Foundation

/// A row's place in its status section — see `AgentListGrouping`. `.flat` is every row exactly as
/// before (an agent with no tree parent, and the whole list while searching or before the tree has
/// loaded): no indent, no decoration.
enum AgentRowNesting: Equatable {
    case flat
    /// A chief's own row, anchoring its group in whichever section the chief itself is shown in.
    /// `needsYouHint` counts the chief's children currently in Needs you, whatever section THIS row
    /// is in — > 0 draws a small "N needs you" hint so that isn't silently invisible even when the
    /// chief's own row sits in Working/Parked/Ended. `machineBadge` mirrors
    /// `AgentTreeNode.machineBadge` ("Air" tag rule carried over from the old tree view).
    case chief(needsYouHint: Int, machineBadge: String?)
    /// A worker nested one level under its chief's anchor row (real or placeholder) in this section.
    case child(crossProject: Bool, machineBadge: String?)
    /// A loose top-level row: never indented, no anchor. `lostParentLabel` set only for a
    /// `AgentTree.parentGone` entry (its chief died) — annotated with who it used to report to.
    case loose(lostParentLabel: String?, machineBadge: String?)
}

/// One line of the switcher list: a status-section header, an agent, or a dimmed placeholder
/// anchoring a chief's children in a section that isn't the chief's own — see `AgentListGrouping`.
enum AgentListRow: Equatable, Identifiable {
    case header(AgentSection)
    case agent(AgentSnapshot, nesting: AgentRowNesting)
    /// A non-interactive stand-in for `node` (a chief) in `section`, shown only because at least one
    /// of the chief's children is in `section` while the chief's own row is shown elsewhere (or not
    /// shown at all) — the group still needs something to nest those children under. `needsYouHint`
    /// mirrors `.chief`'s (same chief, so the same count, wherever its anchor is drawn).
    case chiefPlaceholder(AgentTreeNode, section: AgentSection, needsYouHint: Int)

    var id: String {
        switch self {
        case .header(let section): "section-\(section.rawValue)"
        case .agent(let agent, _): "agent-\(agent.id)"
        case .chiefPlaceholder(let node, let section, _): "chief-placeholder-\(section.rawValue)-\(node.id)"
        }
    }

    /// The agent id when this row can be selected and activated. Headers, placeholders (nothing
    /// real to focus — see `AgentListGrouping`'s doc comment on why the keyboard skips them rather
    /// than jumping to the real chief) and unfocusable agent rows (ended sessions, anything without
    /// a live pane) are skipped by arrow keys and ignore clicks.
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
