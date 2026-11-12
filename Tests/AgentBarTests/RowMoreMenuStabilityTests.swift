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

    // MARK: Gap 7: the menu is the shared RowActionMenu, items unchanged

    @Test func itemsBecomeSharedRowActionsWithTheSameTitles() {
        let view = RowMoreMenuView(
            items: [RowButtonSpec(button: .done, disabledReason: nil), RowButtonSpec(button: .reportTo, disabledReason: nil)],
            isHighlighted: false, reportTargets: ([node("c", status: nil)], [node("w", status: nil)]), onSelect: { _ in }
        )
        let actions = RowMoreMenuView.actions(for: view.menuContent)
        #expect(actions.map(\.title) == [RowButton.done.title, "Report to"])
        #expect(actions[0].submenu.isEmpty)
        #expect(actions[1].submenu.map(\.title) == ["Chiefs", "Workers"])
        #expect(actions[1].submenu[0].actions.map(\.title) == [RowMoreMenuView.targetTitle(node("c", status: nil))])
        #expect(actions[1].submenu[0].actions[0].id == "reportTo:c")
    }

    @Test func aDisabledItemKeepsItsReason() {
        let view = RowMoreMenuView(items: [RowButtonSpec(button: .done, disabledReason: "Busy")], isHighlighted: false, onSelect: { _ in })
        let action = RowMoreMenuView.actions(for: view.menuContent)[0]
        #expect(!action.isEnabled)
        #expect(action.help == "Busy")
    }

    @Test func noReportTargetsShowsADisabledLine() {
        let view = menu([])
        let sub = RowMoreMenuView.actions(for: view.menuContent)[0].submenu
        #expect(sub.count == 1 && sub[0].title == nil)
        #expect(sub[0].actions.map(\.title) == ["No one to report to"])
        #expect(!sub[0].actions[0].isEnabled)
    }

    @Test func reportItemsCarryTheTargetID() {
        #expect(RowMoreMenuView.reportTargetID("reportTo:abc") == "abc")
        #expect(RowMoreMenuView.reportTargetID("reportTo:") == nil)
        #expect(RowMoreMenuView.reportTargetID("Done") == nil)
    }
}
