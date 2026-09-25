import Foundation
import CommandBarKit

/// Nests each status section's rows by the agent hierarchy (`AgentTree`) — the PO's "Nest inside
/// each section" layout (2026-09-25, superseding the earlier "one group per project" layout from
/// 27e611d/01de5de). The four status sections (`AgentSection`) keep their existing order, headers
/// and existing per-section ranking (`AgentRanking`) untouched. INSIDE a section, a worker whose
/// chief is a tree node sits indented directly under an anchor row for that chief: the chief's own
/// real row when the chief is ALSO a member of THIS section, else a dimmed, non-interactive
/// placeholder row (`AgentListRow.chiefPlaceholder`, drawn by `ChiefPlaceholderRowView`) naming the
/// chief — so the section never grows what looks like a second, duplicate chief row. A chief whose
/// children are split across sections gets one anchor per section that holds at least one of them:
/// its real row in its own section, a placeholder in every other one.
///
/// A section's top-level entries (loose agents and chief groups) are ordered in three tiers, in
/// this order (2026-09-25, PO decision — a chief's 7-child group was ranking last in a ~20-agent
/// Needs you section under pure best-rank sorting, so it sat below the fold and went unseen):
///   1. Blocked — any entry with a member blocked on a question/permission (`blockedOnYou != nil`;
///      only possible in Needs you). A group counts as blocked if ANY member is — chief or child.
///   2. Chief groups (anchor + children) not already caught by (1).
///   3. Loose agents not already caught by (1).
/// Within a tier, entries keep today's section ranking (`AgentRanking`) by their best-ranked member
/// (the chief's own rank if its real row is present, plus every child's rank) — so inside a tier a
/// lone high-ranked child can still pull its chief's placeholder above the tier's other groups.
/// Children keep the section's own ranking order among themselves underneath their anchor.
///
/// Pure; no I/O, no SwiftUI. Used only while NOT searching and while a non-empty tree has loaded —
/// `AgentListBuilder` falls back to the old flat sections otherwise (search flattens by design; an
/// unavailable/empty tree has nothing to group by).
enum AgentListGrouping {
    /// A section's top-level-entry tiers, in render order. See the type doc comment above.
    private enum UnitTier: Int, Comparable {
        case blocked = 0
        case chiefGroup = 1
        case loose = 2
        static func < (lhs: UnitTier, rhs: UnitTier) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// `agents` is every shown agent, any section — Needs you included. Nesting is no longer
    /// special-cased there: a blocked worker whose chief is also blocked nests under it exactly
    /// like anywhere else (the old "Needs you dedupe" no longer applies now that every section, not
    /// just Needs you, is nest-aware).
    static func rows(for agents: [AgentSnapshot], tree: AgentTree, frecency: [String: FrecencyEntry], now: Date) -> [AgentListRow] {
        let index = TreeIndex(tree: tree)
        let needsYouIDs = Set(agents.filter { $0.section == .needsYou }.map(\.id))
        return AgentSection.allCases.flatMap { section in
            sectionRows(
                section, agents: agents.filter { $0.section == section },
                index: index, needsYouIDs: needsYouIDs, frecency: frecency, now: now
            )
        }
    }

    /// One section's rows: its header (omitted when the section is empty), then every top-level
    /// entry — a loose agent, or a chief group (anchor row + its children) — ordered by tier, then
    /// best-rank within the tier (`UnitTier`).
    private static func sectionRows(
        _ section: AgentSection, agents: [AgentSnapshot], index: TreeIndex, needsYouIDs: Set<String>,
        frecency: [String: FrecencyEntry], now: Date
    ) -> [AgentListRow] {
        guard !agents.isEmpty else { return [] }
        let ranked = AgentRanking.ordered(agents, in: section, frecency: frecency, now: now)
        let rankOf = Dictionary(uniqueKeysWithValues: ranked.enumerated().map { ($0.element.id, $0.offset) })

        var chiefAgentByChiefID: [String: AgentSnapshot] = [:]
        var childrenByChiefID: [String: [AgentSnapshot]] = [:]
        var looseAgents: [AgentSnapshot] = []
        for agent in agents {
            if let chiefID = index.chiefID(for: agent) {
                chiefAgentByChiefID[chiefID] = agent
            } else if let match = index.childMatch(for: agent) {
                childrenByChiefID[match.chiefID, default: []].append(agent)
            } else {
                looseAgents.append(agent)
            }
        }

        var units: [(tier: UnitTier, rank: Int, rows: [AgentListRow])] = []

        for chiefID in Set(chiefAgentByChiefID.keys).union(childrenByChiefID.keys) {
            // Always true by construction: `chiefID` only ever comes from `index`, which sources
            // both maps from `tree.chiefs` in the first place.
            guard let node = index.chief(withID: chiefID) else { continue }
            let children = childrenByChiefID[chiefID] ?? []
            let orderedChildren = ranked.filter { agent in children.contains { $0.id == agent.id } }
            var memberRanks = orderedChildren.compactMap { rankOf[$0.id] }
            var isBlocked = orderedChildren.contains { $0.blockedOnYou != nil }

            var rows: [AgentListRow] = []
            let needsYouHint = index.needsYouHint(node, needsYouIDs: needsYouIDs)
            if let chiefAgent = chiefAgentByChiefID[chiefID] {
                if let rank = rankOf[chiefAgent.id] { memberRanks.append(rank) }
                if chiefAgent.blockedOnYou != nil { isBlocked = true }
                rows.append(.agent(chiefAgent, nesting: .chief(needsYouHint: needsYouHint, machineBadge: node.machineBadge)))
            } else {
                rows.append(.chiefPlaceholder(node, section: section, needsYouHint: needsYouHint))
            }
            rows.append(contentsOf: orderedChildren.map { child in
                let childNode = index.childMatch(for: child)?.node
                return .agent(child, nesting: .child(crossProject: childNode?.crossProject ?? false, machineBadge: childNode?.machineBadge))
            })

            guard let bestRank = memberRanks.min() else { continue }
            units.append((tier: isBlocked ? .blocked : .chiefGroup, rank: bestRank, rows: rows))
        }

        for agent in looseAgents {
            let tier: UnitTier = agent.blockedOnYou != nil ? .blocked : .loose
            units.append((tier: tier, rank: rankOf[agent.id] ?? Int.max, rows: [.agent(agent, nesting: index.looseNesting(for: agent))]))
        }

        // Within a tier, every unit's best rank is a distinct agent's own rank index (each agent
        // belongs to exactly one unit), so the rank comparison is already unambiguous there.
        units.sort { lhs, rhs in
            lhs.tier != rhs.tier ? lhs.tier < rhs.tier : lhs.rank < rhs.rank
        }
        return [.header(section)] + units.flatMap(\.rows)
    }
}

/// Tree lookups shared by every section pass, built once per call. An agent can match a tree node
/// either by id or by pane id (the same fallback the pre-2026-09-25 grouping used) — kept as a
/// private helper here rather than on `AgentTree` itself, since nothing outside this file needs it.
private struct TreeIndex {
    struct ChildMatch { let chiefID: String; let node: AgentTreeNode }

    private let chiefsByID: [String: AgentTreeNode]
    private let chiefsByPaneID: [String: AgentTreeNode]
    private let childMatchByID: [String: ChildMatch]
    private let childMatchByPaneID: [String: ChildMatch]
    private let looseMachineBadgeByID: [String: String]
    private let looseMachineBadgeByPaneID: [String: String]
    private let lostParentLabelByID: [String: String]
    private let lostParentLabelByPaneID: [String: String]

    init(tree: AgentTree) {
        chiefsByID = Dictionary(tree.chiefs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        chiefsByPaneID = Dictionary(
            tree.chiefs.compactMap { chief in chief.paneId.map { ($0, chief) } }, uniquingKeysWith: { first, _ in first }
        )

        var childByID: [String: ChildMatch] = [:]
        var childByPaneID: [String: ChildMatch] = [:]
        for chief in tree.chiefs {
            for child in chief.children {
                let match = ChildMatch(chiefID: chief.id, node: child)
                childByID[child.id] = match
                if let paneId = child.paneId { childByPaneID[paneId] = match }
            }
        }
        childMatchByID = childByID
        childMatchByPaneID = childByPaneID

        var badgeByID: [String: String] = [:]
        var badgeByPaneID: [String: String] = [:]
        var lostByID: [String: String] = [:]
        var lostByPaneID: [String: String] = [:]
        for node in tree.unassigned {
            if let badge = node.machineBadge {
                badgeByID[node.id] = badge
                if let paneId = node.paneId { badgeByPaneID[paneId] = badge }
            }
        }
        for entry in tree.parentGone {
            lostByID[entry.node.id] = entry.lostParentLabel
            if let paneId = entry.node.paneId { lostByPaneID[paneId] = entry.lostParentLabel }
            if let badge = entry.node.machineBadge {
                badgeByID[entry.node.id] = badge
                if let paneId = entry.node.paneId { badgeByPaneID[paneId] = badge }
            }
        }
        looseMachineBadgeByID = badgeByID
        looseMachineBadgeByPaneID = badgeByPaneID
        lostParentLabelByID = lostByID
        lostParentLabelByPaneID = lostByPaneID
    }

    /// The tree id of the chief `agent` itself is, if it is one.
    func chiefID(for agent: AgentSnapshot) -> String? {
        (chiefsByID[agent.id] ?? agent.paneId.flatMap { chiefsByPaneID[$0] })?.id
    }

    func chief(withID id: String) -> AgentTreeNode? { chiefsByID[id] }

    /// The chief `agent` reports to, if it is a tracked worker.
    func childMatch(for agent: AgentSnapshot) -> ChildMatch? {
        childMatchByID[agent.id] ?? agent.paneId.flatMap { childMatchByPaneID[$0] }
    }

    /// Every child of `chief`, whatever section each is currently shown in, that is in Needs you.
    func needsYouHint(_ chief: AgentTreeNode, needsYouIDs: Set<String>) -> Int {
        chief.children.filter { needsYouIDs.contains($0.id) }.count
    }

    /// `.loose` nesting for an agent that is neither a chief nor a tracked worker: `tree.unassigned`
    /// and `tree.parentGone` entries carry their machine badge / lost-parent label through; an agent
    /// the tree never mentions at all gets neither — today's plain `.flat`, unchanged.
    func looseNesting(for agent: AgentSnapshot) -> AgentRowNesting {
        let lostParentLabel = lostParentLabelByID[agent.id] ?? agent.paneId.flatMap { lostParentLabelByPaneID[$0] }
        let machineBadge = looseMachineBadgeByID[agent.id] ?? agent.paneId.flatMap { looseMachineBadgeByPaneID[$0] }
        guard lostParentLabel != nil || machineBadge != nil else { return .flat }
        return .loose(lostParentLabel: lostParentLabel, machineBadge: machineBadge)
    }
}
