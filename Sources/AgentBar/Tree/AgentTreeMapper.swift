import Foundation

/// Turns one `agentTree` wire payload into the domain `AgentTree`. Pure: no I/O, no clock. Mirrors
/// `StatusSnapshotBuilder`/`LiveAgentMapper`'s split of "decode" from "map to what the UI uses".
enum AgentTreeMapper {
    /// A fresh formatter per call rather than a shared static: `ISO8601DateFormatter` is not
    /// `Sendable`, and mapping runs at most once per ~2s snapshot, so there's no reuse to buy back.
    static func map(_ wire: AgentTreeWirePayload?) -> AgentTree? {
        guard let wire else { return nil }
        return AgentTree(
            generatedAt: wire.generatedAt.flatMap(ISO8601DateFormatter().date(from:)),
            chiefs: wire.chiefs.compactMap(chiefNode),
            unassigned: wire.unassigned.compactMap(workerNode),
            parentGone: wire.parentGone.compactMap(parentGoneEntry)
        )
    }

    /// A chief missing its own id or label is dropped: there's nothing usable to show or act on,
    /// and dropping it entirely (rather than keeping a blank row) also drops its children from the
    /// tree — better than showing workers attached to a row with no name to attach/detach against.
    private static func chiefNode(_ wire: AgentTreeWireChief) -> AgentTreeNode? {
        guard let id = wire.id, let label = wire.label else { return nil }
        return AgentTreeNode(
            id: id, label: label, project: wire.project ?? "", projectRoot: wire.projectRoot,
            machine: wire.machine ?? "local", paneId: wire.paneId, alive: wire.alive ?? false,
            status: wire.status, crossProject: false, isChiefMode: wire.isChiefMode ?? false,
            children: wire.children.compactMap(workerNode)
        )
    }

    private static func workerNode(_ wire: AgentTreeWireAgent) -> AgentTreeNode? {
        guard let id = wire.id, let label = wire.label else { return nil }
        return AgentTreeNode(
            id: id, label: label, project: wire.project ?? "", projectRoot: wire.projectRoot,
            machine: wire.machine ?? "local", paneId: wire.paneId, alive: wire.alive ?? false,
            status: wire.status, crossProject: wire.crossProject ?? false, isChiefMode: false
        )
    }

    /// A parent-gone entry missing the lost-parent's id/label is dropped too: the whole point of
    /// this section is naming who it used to report to (the row itself is drawn from `node`).
    private static func parentGoneEntry(_ wire: AgentTreeWireAgent) -> AgentTree.ParentGoneEntry? {
        guard let node = workerNode(wire), let lostParent = wire.lostParent,
              let lostParentID = lostParent.id, let lostParentLabel = lostParent.label
        else { return nil }
        return AgentTree.ParentGoneEntry(node: node, lostParentID: lostParentID, lostParentLabel: lostParentLabel)
    }
}
