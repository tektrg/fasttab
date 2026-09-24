import Foundation

/// One row as the tree view draws it, top to bottom.
enum AgentTreeDisplayRow: Equatable {
    case parentGone(AgentTree.ParentGoneEntry)
    case chief(AgentTreeNode)
    case child(AgentTreeNode)
    case unassigned(AgentTreeNode)

    var nodeID: String {
        switch self {
        case .parentGone(let entry): entry.node.id
        case .chief(let node): node.id
        case .child(let node): node.id
        case .unassigned(let node): node.id
        }
    }
}

/// The flattened top-to-bottom row order the hierarchy uses for "nearest chief above", and what
/// Indent (⌘]) targets from it. Kept separate from `AgentTreeModel` (and its tests) so both it and
/// `AgentListGrouping` (which flattens the same tree its own way, for the merged list's rows) agree
/// on what "above" means without either inventing its own order.
enum AgentTreeDisplayOrder {
    /// Parent-gone first (never hidden, always at the top), then each chief with its workers
    /// indented beneath it in the server's own order, then Unassigned.
    static func flatten(_ tree: AgentTree) -> [AgentTreeDisplayRow] {
        var rows: [AgentTreeDisplayRow] = tree.parentGone.map(AgentTreeDisplayRow.parentGone)
        for chief in tree.chiefs {
            rows.append(.chief(chief))
            rows.append(contentsOf: chief.children.map(AgentTreeDisplayRow.child))
        }
        rows.append(contentsOf: tree.unassigned.map(AgentTreeDisplayRow.unassigned))
        return rows
    }

    /// The nearest chief row strictly above `id` in display order — what Indent (⌘]) attaches to.
    /// Nil when nothing above `id` is a chief (`id` is in the Parent-gone section, which is always
    /// first, or is itself the first chief).
    static func nearestChief(above id: String, in rows: [AgentTreeDisplayRow]) -> AgentTreeNode? {
        guard let index = rows.firstIndex(where: { $0.nodeID == id }) else { return nil }
        for row in rows[..<index].reversed() {
            if case .chief(let node) = row { return node }
        }
        return nil
    }
}
