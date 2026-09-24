import Foundation

/// The row-menu equivalents of ⌘] / ⌘[ (`AgentTreeModel.indentSelected`/`outdentSelected`) —
/// "Report to…" and "Stop reporting" in the row's existing ⋯ menu, alongside Done/Close
/// pane/Compact/Clear. Kept separate from `RowButtons` (which stays agent-only and pure, per its
/// existing tests) because these two depend on the hierarchy tree, not just the agent's own
/// section — this is the small piece that combines them.
enum TreeRowActions {
    /// "Report to…"/"Stop reporting" for one row, given where it sits in `tree` — empty when the
    /// tree hasn't loaded, or the agent isn't tracked by it at all (nothing to attach/detach
    /// against). A chief never gets either (two levels only, chiefs aren't attached to anyone).
    /// "Stop reporting" only appears once there is somewhere to detach FROM — a worker already
    /// nested under a live chief; Parent-gone and Unassigned rows only get "Report to…".
    static func menuItems(forAgentID id: String, tree: AgentTree?) -> [RowButtonSpec] {
        guard let tree, let node = tree.node(withID: id), !tree.isChief(id) else { return [] }
        let hasLiveParent = tree.chiefs.contains { $0.children.contains { $0.id == node.id } }
        var items = [RowButtonSpec(button: .reportTo, disabledReason: nil)]
        if hasLiveParent { items.append(RowButtonSpec(button: .stopReporting, disabledReason: nil)) }
        return items
    }

    /// `RowButtons.available(for:)` plus a `.moreActions` trigger if the tree items alone would
    /// need one that the agent's own section didn't already offer (e.g. a plain Working row with
    /// no Message eligibility still needs a way to reach "Report to…").
    static func availableButtons(for agent: AgentSnapshot, tree: AgentTree?) -> [RowButtonSpec] {
        var buttons = RowButtons.available(for: agent)
        guard buttons.first(where: { $0.button == .moreActions }) == nil else { return buttons }
        guard !menuItems(forAgentID: agent.id, tree: tree).isEmpty else { return buttons }
        buttons.append(RowButtonSpec(button: .moreActions, disabledReason: nil))
        return buttons
    }

    /// `RowButtons.menuItems(for:)` plus this row's tree items.
    static func allMenuItems(for agent: AgentSnapshot, tree: AgentTree?) -> [RowButtonSpec] {
        RowButtons.menuItems(for: agent) + menuItems(forAgentID: agent.id, tree: tree)
    }

    /// `RowButtons.isPressable`, extended to know about `.reportTo`/`.stopReporting`.
    static func isPressable(_ button: RowButton, on agent: AgentSnapshot, tree: AgentTree?) -> Bool {
        if button == .reportTo || button == .stopReporting {
            return menuItems(forAgentID: agent.id, tree: tree).contains { $0.button == button && $0.isEnabled }
        }
        return RowButtons.isPressable(button, on: agent)
    }
}
