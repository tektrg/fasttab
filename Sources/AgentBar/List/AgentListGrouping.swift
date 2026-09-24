import Foundation
import CommandBarKit

/// Groups the non-Needs-you rows by the agent hierarchy (`AgentTree`) instead of by status — the
/// PO-decided "Nest under chief" layout: Needs you stays flat and on top (built by the caller,
/// unchanged), then one group per chief's project (the chief's row, its workers indented beneath
/// it), then a single Unassigned group for everything else. Pure; no I/O, no SwiftUI.
///
/// Used only while NOT searching and while a non-empty tree has loaded — `AgentListBuilder`
/// falls back to the old flat status sections otherwise (search flattens by design; an
/// unavailable/empty tree has nothing to group by).
enum AgentListGrouping {
    /// `agents` is every shown agent NOT in Needs you (the caller already split that out). Builds:
    /// one `.groupHeader(.project(_))` + chief/child rows per project the tree's chiefs belong to,
    /// server order (first chief seen decides where its project's group sits; a second chief for an
    /// already-seen project joins that same group, right after the first), then a trailing
    /// `.groupHeader(.unassigned)` + flat rows for `tree.unassigned`, `tree.parentGone`, and any
    /// agent the tree doesn't know about at all (never hidden — everything shown ends up somewhere).
    static func rows(for agents: [AgentSnapshot], tree: AgentTree, needsYouIDs: Set<String>, frecency: [String: FrecencyEntry], now: Date) -> [AgentListRow] {
        let byID = Dictionary(agents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let byPaneID = Dictionary(agents.compactMap { agent in agent.paneId.map { ($0, agent) } }, uniquingKeysWith: { first, _ in first })
        func snapshot(for node: AgentTreeNode) -> AgentSnapshot? {
            byID[node.id] ?? node.paneId.flatMap { byPaneID[$0] }
        }

        var consumed = Set<String>()
        var rows: [AgentListRow] = []

        for project in projectOrder(of: tree.chiefs) {
            let chiefs = tree.chiefs.filter { $0.project == project }
            var groupRows: [AgentListRow] = []
            for chief in chiefs {
                consumed.insert(chief.id)
                let needsYouHint = chief.children.filter { needsYouIDs.contains($0.id) }.count
                // A chief itself blocked on you is shown only in Needs you (same dedupe as a
                // worker) — its group still holds its children, just without its own row.
                if !needsYouIDs.contains(chief.id), let chiefAgent = snapshot(for: chief) {
                    groupRows.append(.agent(chiefAgent, nesting: .chief(needsYouHint: needsYouHint, machineBadge: chief.machineBadge)))
                }
                let children: [(AgentTreeNode, AgentSnapshot)] = chief.children.compactMap { node in
                    guard !needsYouIDs.contains(node.id) else { return nil }
                    consumed.insert(node.id)
                    guard let childAgent = snapshot(for: node) else { return nil }
                    return (node, childAgent)
                }
                let nodeByID = Dictionary(uniqueKeysWithValues: children.map { ($0.0.id, $0.0) })
                let ordered = AgentRanking.orderedByFrecency(children.map(\.1), frecency: frecency, now: now)
                groupRows.append(contentsOf: ordered.map { agent -> AgentListRow in
                    let node = nodeByID[agent.id]
                    return .agent(agent, nesting: .child(crossProject: node?.crossProject ?? false, machineBadge: node?.machineBadge))
                })
            }
            guard !groupRows.isEmpty else { continue }
            rows.append(.groupHeader(AgentGroupHeader(kind: .project(project))))
            rows.append(contentsOf: groupRows)
        }

        // Unassigned: tree.unassigned, tree.parentGone, then any shown agent the tree never
        // mentioned at all (untracked, e.g. non-hierarchy-aware panes) — "everything else".
        var lostParentByID: [String: String] = [:]
        var machineBadgeByID: [String: String] = [:]
        var unassignedAgents: [AgentSnapshot] = []
        func addUnassigned(_ node: AgentTreeNode) {
            guard !needsYouIDs.contains(node.id), !consumed.contains(node.id) else { return }
            consumed.insert(node.id)
            guard let agent = snapshot(for: node) else { return }
            unassignedAgents.append(agent)
            if let badge = node.machineBadge { machineBadgeByID[node.id] = badge }
        }
        for entry in tree.parentGone {
            addUnassigned(entry.node)
            if consumed.contains(entry.node.id) { lostParentByID[entry.node.id] = entry.lostParentLabel }
        }
        for node in tree.unassigned {
            addUnassigned(node)
        }
        for agent in agents where !consumed.contains(agent.id) && !needsYouIDs.contains(agent.id) {
            consumed.insert(agent.id)
            unassignedAgents.append(agent)
        }
        if !unassignedAgents.isEmpty {
            let ordered = AgentRanking.orderedByFrecency(unassignedAgents, frecency: frecency, now: now)
            rows.append(.groupHeader(AgentGroupHeader(kind: .unassigned)))
            rows.append(contentsOf: ordered.map { agent in
                .agent(agent, nesting: .unassigned(lostParentLabel: lostParentByID[agent.id], machineBadge: machineBadgeByID[agent.id]))
            })
        }
        return rows
    }

    /// Projects in first-appearance order among the server's own chief order — so a second chief
    /// for an already-seen project doesn't split into a duplicate group further down.
    private static func projectOrder(of chiefs: [AgentTreeNode]) -> [String] {
        var seen = Set<String>()
        var order: [String] = []
        for chief in chiefs where !seen.contains(chief.project) {
            seen.insert(chief.project)
            order.append(chief.project)
        }
        return order
    }
}
