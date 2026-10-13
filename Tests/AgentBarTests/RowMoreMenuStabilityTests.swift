import Foundation
import Testing
@testable import AgentBar

/// A dashboard refresh that changes only status/children must not count as a menu change —
/// re-rendering rebuilds the native menu and closed an open "Report to" submenu (2026-10-10).
@MainActor
struct RowMoreMenuStabilityTests {
    private func node(_ id: String, status: String?, children: [AgentTreeNode] = []) -> AgentTreeNode {
        AgentTreeNode(id: id, label: id, project: "proj", projectRoot: nil, machine: "local", paneId: nil,
                      alive: true, status: status, crossProject: false, isChiefMode: true, children: children)
    }

    private func menu(_ chiefs: [AgentTreeNode]) -> RowMoreMenuView {
        RowMoreMenuView(items: [RowButtonSpec(button: .reportTo, disabledReason: nil)], isHighlighted: false,
                        reportTargets: (chiefs, []), onSelect: { _ in })
    }

    @Test func aRefreshThatOnlyChangesStatusOrChildrenIsEqual() {
        #expect(menu([node("c", status: "working")]) == menu([node("c", status: "idle", children: [node("w", status: nil)])]))
    }

    @Test func aChangedTargetTitleIsNotEqual() {
        #expect(menu([node("c", status: nil)]) != menu([node("d", status: nil)]))
    }
}
