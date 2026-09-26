import Foundation

/// Which row id `AgentListView` should hand `ScrollViewReader.scrollTo` when the selection changes.
/// Pure — no SwiftUI. Exists because scrolling straight to the selected agent's own row can shove
/// non-selectable rows it belongs to (its section header, its group's chief/placeholder anchor) off
/// the top of the viewport, so the PO can no longer tell which chief a nested worker reports to.
///
/// Two rules, applied in order (2026-09-25, fixing exactly that: launch pre-selects the first
/// worker under the first chief, hiding both "Needs you" and the chief anchor above it):
///   1. If the selection is the list's very first selectable row, there is nothing above it that
///      isn't part of its own context — scroll all the way to the top (`rows.first`, its section
///      header) instead of to the row itself.
///   2. Otherwise, if the selection is a `.child` nesting, scroll to its group's anchor row (the
///      chief's real row or its `chiefPlaceholder`) rather than the child's own row, so the anchor
///      stays in view alongside it.
///   Anything else (a chief row, a loose row, a non-first child with no anchor to reveal) scrolls
///   to its own row, same as before.
enum AgentListScrollTarget {
    static func id(forSelecting agentID: String, in rows: [AgentListRow]) -> String? {
        let ownRowID = "agent-\(agentID)"
        guard let index = rows.firstIndex(where: { $0.id == ownRowID }) else { return nil }

        if rows.compactMap(\.selectableAgentID).first == agentID {
            return rows.first?.id
        }

        if case .agent(_, let nesting) = rows[index], case .child = nesting {
            return anchorRowID(above: index, in: rows) ?? ownRowID
        }

        return ownRowID
    }

    /// Walks backward from `index` over consecutive `.child` rows (same group) to the anchor row
    /// that started them: a chief's real row (`.chief` nesting) or a `.chiefPlaceholder`.
    private static func anchorRowID(above index: Int, in rows: [AgentListRow]) -> String? {
        var i = index - 1
        while i >= 0 {
            switch rows[i] {
            case .chiefPlaceholder:
                return rows[i].id
            case .agent(_, let nesting):
                if case .chief = nesting { return rows[i].id }
                if case .child = nesting { i -= 1; continue }
                return nil
            case .header:
                return nil
            }
        }
        return nil
    }
}
