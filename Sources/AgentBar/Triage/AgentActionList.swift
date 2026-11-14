import Foundation

/// One entry of the shared action row (`AgentActionRow`): the host surface's Close, Go to agent, or
/// one of the row's ⋯ menu buttons (pressed through `AgentPanelModel.press`, same gates as the menu).
enum AgentAction: Hashable, Sendable {
    case close
    case goToAgent
    case row(RowButton)
}

struct AgentActionItem: Equatable, Sendable, Identifiable {
    let action: AgentAction
    let title: String
    let isEnabled: Bool
    /// Tooltip: why it is disabled, else the button's hint.
    let help: String?
    /// The ⋯ spec behind a `.row` item (nil for Close / Go to agent) — the capsule's confirm/busy titles come from it.
    let spec: RowButtonSpec?

    var id: AgentAction { action }
}

/// The action row's items. Pure. The ⋯ part is `menuItems(for:tree:)` — the SAME list the row's ⋯
/// menu shows (`AgentRowView.menuItems` calls it), so the two can never drift.
enum AgentActionList {
    static let closeTitle = "Close"
    static let goToTitle = "Go to agent"
    static let moreTitle = "More…"

    /// Exactly what the row's ⋯ menu holds: the capsules that moved into it (Peek, Park, Message…),
    /// the menu's own items (Done, Close pane, Compact, Clear, Resume on next account), then the tree items.
    static func menuItems(for agent: AgentSnapshot, tree: AgentTree?) -> [RowButtonSpec] {
        menuItems(for: agent, treeItems: TreeRowActions.menuItems(forAgentID: agent.id, tree: tree))
    }

    static func menuItems(for agent: AgentSnapshot, treeItems: [RowButtonSpec]) -> [RowButtonSpec] {
        RowButtons.movedIntoMenu(RowButtons.available(for: agent)) + RowButtons.menuItems(for: agent) + treeItems
    }

    /// Close, Go to agent (when the host has one; `goToDisabledReason` greys it), then the ⋯ items
    /// minus `hiding` (buttons the host already shows another way, e.g. Focus mode's Message box).
    static func items(
        for agent: AgentSnapshot, tree: AgentTree?, includesGoTo: Bool = true,
        goToDisabledReason: String? = nil, hiding: Set<RowButton> = []
    ) -> [AgentActionItem] {
        var items = [AgentActionItem(action: .close, title: closeTitle, isEnabled: true, help: nil, spec: nil)]
        if includesGoTo {
            items.append(AgentActionItem(
                action: .goToAgent, title: goToTitle, isEnabled: goToDisabledReason == nil, help: goToDisabledReason, spec: nil
            ))
        }
        items += menuItems(for: agent, tree: tree)
            .filter { !hiding.contains($0.button) }
            .map { AgentActionItem(action: .row($0.button), title: $0.label, isEnabled: $0.isEnabled, help: $0.disabledReason ?? $0.hint, spec: $0) }
        return items
    }

    /// The row's layouts to try, best first: all items, then one fewer (+ "More…"), down to only "More…".
    static func candidateCounts(itemCount: Int) -> [Int] { Array((0...max(0, itemCount)).reversed()) }
}
