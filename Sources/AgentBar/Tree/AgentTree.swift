import Foundation

/// One agent in the hierarchy: a chief (supervises workers) or a worker (reports to a chief, or to
/// nobody). Two levels only — a chief's own `children` are always workers, never chiefs.
struct AgentTreeNode: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let project: String
    let projectRoot: String?
    /// "local" | "air-m1".
    let machine: String
    let paneId: String?
    let alive: Bool
    let status: String?
    /// True when this worker's project differs from the chief it is shown under (server-computed).
    let crossProject: Bool
    /// Meaningful only on a chief row.
    let isChiefMode: Bool
    var children: [AgentTreeNode]

    init(
        id: String, label: String, project: String, projectRoot: String?, machine: String, paneId: String?,
        alive: Bool, status: String?, crossProject: Bool, isChiefMode: Bool, children: [AgentTreeNode] = []
    ) {
        self.id = id
        self.label = label
        self.project = project
        self.projectRoot = projectRoot
        self.machine = machine
        self.paneId = paneId
        self.alive = alive
        self.status = status
        self.crossProject = crossProject
        self.isChiefMode = isChiefMode
        self.children = children
    }

    /// "Air" for a node running on `air-m1`; nil for `local` (the badge is omitted entirely, per
    /// the feature brief: "nothing for local").
    var machineBadge: String? { machine == "air-m1" ? "Air" : nil }
}

/// Who reports to whom, as the dashboard computes it: chiefs with their workers, workers reporting
/// nowhere (`unassigned`, i.e. muted), and workers whose chief died (`parentGone` — must never be
/// hidden, always shown first). Two levels only: nothing here nests deeper than chief -> worker.
struct AgentTree: Equatable, Sendable {
    /// A `parentGone` worker, plus who it used to report to (the dead chief's id/label — the chief
    /// row itself is gone from `chiefs`, so this is the only place that name survives).
    struct ParentGoneEntry: Identifiable, Equatable, Sendable {
        let node: AgentTreeNode
        let lostParentID: String
        let lostParentLabel: String
        var id: String { node.id }
    }

    let generatedAt: Date?
    var chiefs: [AgentTreeNode]
    var unassigned: [AgentTreeNode]
    var parentGone: [ParentGoneEntry]

    static let empty = AgentTree(generatedAt: nil, chiefs: [], unassigned: [], parentGone: [])

    var isEmpty: Bool { chiefs.isEmpty && unassigned.isEmpty && parentGone.isEmpty }

    /// True when `id` names one of `chiefs` — never a worker, even one with the same id shape.
    func isChief(_ id: String) -> Bool { chiefs.contains { $0.id == id } }

    /// Finds a node anywhere in the tree: a chief, one of its children, unassigned, or parent-gone.
    func node(withID id: String) -> AgentTreeNode? {
        if let chief = chiefs.first(where: { $0.id == id }) { return chief }
        for chief in chiefs {
            if let child = chief.children.first(where: { $0.id == id }) { return child }
        }
        if let node = unassigned.first(where: { $0.id == id }) { return node }
        if let entry = parentGone.first(where: { $0.node.id == id }) { return entry.node }
        return nil
    }

    /// True when `id` can take a report: a chief, or an Unassigned worker (who becomes a chief by
    /// taking one — the server's two-level rule only refuses a parent that itself reports to someone,
    /// so a nested or Parent-gone worker can't).
    func canBeParent(_ id: String) -> Bool { isChief(id) || unassigned.contains { $0.id == id } }

    /// Who the row `childID` can report to ("Report to" submenu): live chiefs, then live Unassigned
    /// workers — never itself, nor the chief it already reports to. Same-project ones first within
    /// each group, server order otherwise. Empty for a chief (two levels only) or an unknown id.
    func reportTargets(for childID: String) -> (chiefs: [AgentTreeNode], workers: [AgentTreeNode]) {
        guard !isChief(childID), let child = node(withID: childID) else { return ([], []) }
        func eligible(_ nodes: [AgentTreeNode]) -> [AgentTreeNode] {
            let live = nodes.filter { $0.alive && $0.id != childID }
            return live.filter { $0.project == child.project } + live.filter { $0.project != child.project }
        }
        let currentParents = chiefs.filter { $0.children.contains { $0.id == childID } }
        return (eligible(chiefs.filter { !currentParents.contains($0) }), eligible(unassigned))
    }

    /// `child` reassigned to report to `parentID` (a chief, or an Unassigned worker promoted to a
    /// chief by this): removed from wherever it was (another chief's children, unassigned, or
    /// parent-gone) and appended under the new parent. A no-op if `parentID` can't be a parent or
    /// `childID` is a chief itself — callers should already have refused that (the two-level rule),
    /// this is only a last line of defense against a stale optimistic apply.
    func movingChild(_ childID: String, toChiefID parentID: String) -> AgentTree {
        guard !isChief(childID), let child = node(withID: childID), canBeParent(parentID), childID != parentID else { return self }
        var tree = removingChild(childID)
        if let index = tree.unassigned.firstIndex(where: { $0.id == parentID }) {
            tree.chiefs.append(tree.unassigned.remove(at: index))
        }
        tree.chiefs = tree.chiefs.map { chief in
            guard chief.id == parentID else { return chief }
            var chief = chief
            chief.children.append(child)
            return chief
        }
        return tree
    }

    /// `child` moved to Unassigned, removed from wherever it was.
    func movingChildToUnassigned(_ childID: String) -> AgentTree {
        guard !isChief(childID), let child = node(withID: childID) else { return self }
        var tree = removingChild(childID)
        tree.unassigned.append(child)
        return tree
    }

    private func removingChild(_ childID: String) -> AgentTree {
        var tree = self
        tree.chiefs = tree.chiefs.map { chief in
            var chief = chief
            chief.children.removeAll { $0.id == childID }
            return chief
        }
        tree.unassigned.removeAll { $0.id == childID }
        tree.parentGone.removeAll { $0.node.id == childID }
        return tree
    }
}
