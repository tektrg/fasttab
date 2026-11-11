/// Focus mode's queue: the agents that need you, one shown at a time (pure, unit-tested).
///
/// Rules (PO, 2026-11-11):
/// - Order = the AgentBar list's order at the moment each agent joins. Agents already queued keep
///   their place; newcomers are appended at the END (in list order), so an arrival never steals
///   the card the user is reading.
/// - An agent that leaves (answered here or elsewhere, parked, gone) is dropped; the card moves to
///   the agent that was after it (or the one before, when it was last). Position is kept.
/// - ⌘← / ⌘→ do NOT wrap: at either end they are inert (the view bumps). With 1 agent both are inert.
/// - An agent answered in Focus mode is remembered as handled until it drops out of the list, so
///   the dashboard's few-seconds lag does not bring the card straight back.
struct FocusQueue: Equatable {
    private(set) var agentIDs: [String] = []
    private(set) var currentIndex = 0
    private(set) var handledIDs: Set<String> = []

    init(listOrder: [String] = []) {
        update(listOrder: listOrder)
        currentIndex = 0
    }

    var currentID: String? { agentIDs.indices.contains(currentIndex) ? agentIDs[currentIndex] : nil }
    var isAllClear: Bool { agentIDs.isEmpty }
    var count: Int { agentIDs.count }
    /// 1-based, for "2 of 4"; nil when all clear.
    var position: Int? { currentID == nil ? nil : currentIndex + 1 }
    var canMoveBack: Bool { currentIndex > 0 }
    var canMoveForward: Bool { currentIndex + 1 < agentIDs.count }

    /// A fresh reading of who needs you, in list order.
    mutating func update(listOrder: [String]) {
        let present = Set(listOrder)
        handledIDs.formIntersection(present)
        let wanted = listOrder.filter { !handledIDs.contains($0) }
        let wantedSet = Set(wanted)
        remove(where: { !wantedSet.contains($0) })
        let known = Set(agentIDs)
        agentIDs += wanted.filter { !known.contains($0) }
    }

    /// The user answered `agentID` here: drop it now and keep it out until it leaves the list.
    mutating func markHandled(_ agentID: String) {
        handledIDs.insert(agentID)
        remove(where: { $0 == agentID })
    }

    @discardableResult
    mutating func moveForward() -> Bool {
        guard canMoveForward else { return false }
        currentIndex += 1
        return true
    }

    @discardableResult
    mutating func moveBack() -> Bool {
        guard canMoveBack else { return false }
        currentIndex -= 1
        return true
    }

    /// Drops matching ids, keeping the card on the same agent, or on the one that took the
    /// removed current agent's place (the previous one when it was last).
    private mutating func remove(where shouldRemove: (String) -> Bool) {
        let current = currentID
        let removedBefore = agentIDs.prefix(currentIndex).filter(shouldRemove).count
        agentIDs.removeAll(where: shouldRemove)
        if let current, let index = agentIDs.firstIndex(of: current) {
            currentIndex = index
        } else {
            currentIndex = max(0, min(currentIndex - removedBefore, agentIDs.count - 1))
        }
    }

    /// The needs-you agents' ids in the list's display order; any not shown in the list (a search
    /// hid it) follow in their feed order.
    static func listOrder(needsYou: [String], displayOrder: [String]) -> [String] {
        let wanted = Set(needsYou)
        let shown = displayOrder.filter { wanted.contains($0) }
        let shownSet = Set(shown)
        return shown + needsYou.filter { !shownSet.contains($0) }
    }
}
