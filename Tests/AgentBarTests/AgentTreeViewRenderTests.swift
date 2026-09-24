import AppKit
import SwiftUI
import Testing
@testable import AgentBar

/// The Agent Hierarchy view draws its main states without breaking layout. Renders off-screen
/// (`NSHostingView` + `bitmapImageRepForCachingDisplay`), the same technique as
/// `MessageCardViewRenderTests`/`PlanCardViewRenderTests` — no live window, no screen interaction.
/// Set `AGENT_TREE_RENDER_DIR` to keep the PNGs.
@MainActor @Suite(.serialized)
struct AgentTreeViewRenderTests {
    private func node(_ id: String, label: String? = nil, project: String = "AptusFit", machine: String = "local", status: String? = nil, crossProject: Bool = false) -> AgentTreeNode {
        AgentTreeNode(
            id: id, label: label ?? id, project: project, projectRoot: nil, machine: machine, paneId: "w1:\(id)",
            alive: true, status: status, crossProject: crossProject, isChiefMode: false
        )
    }

    private func chief(_ id: String, project: String = "AptusFit", machine: String = "local", children: [AgentTreeNode] = []) -> AgentTreeNode {
        AgentTreeNode(
            id: id, label: id, project: project, projectRoot: nil, machine: machine, paneId: "w1:\(id)",
            alive: true, status: "supervising", crossProject: false, isChiefMode: true, children: children
        )
    }

    private func populatedTree() -> AgentTree {
        AgentTree(
            generatedAt: nil,
            chiefs: [
                chief("chief-aptusfit", project: "AptusFit", children: [
                    node("worker-a", label: "122-plan-day-fix", status: "implementing"),
                    node("worker-b", label: "conditioning-weightload", machine: "air-m1", status: "needs you"),
                ]),
                chief("chief-speechtodo", project: "SpeechToDo", children: [
                    node("worker-c", label: "cross-project-worker", project: "AptusFit", status: "working", crossProject: true),
                ]),
            ],
            unassigned: [node("worker-d", label: "lone-agent", status: "working")],
            parentGone: [
                AgentTree.ParentGoneEntry(node: node("worker-e", label: "orphaned-worker", machine: "air-m1", status: "waiting"), lostParentID: "chief-dead", lostParentLabel: "chief-dead (closed)"),
            ]
        )
    }

    private func render(_ model: AgentTreeModel, name: String) -> NSBitmapImageRep? {
        let host = NSHostingView(rootView: AgentTreeView(model: model).frame(width: AgentTreeView.width, height: AgentTreeView.height))
        host.frame = CGRect(x: 0, y: 0, width: AgentTreeView.width, height: AgentTreeView.height)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if let path = ProcessInfo.processInfo.environment["AGENT_TREE_RENDER_DIR"], let png = bitmap.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path).appendingPathComponent("agent-tree-\(name).png"))
        }
        return bitmap
    }

    @Test func populatedTreeDraws() {
        let model = AgentTreeModel()
        model.receive(StatusSnapshot(agents: [], health: .ok, fetchedAt: Date(), boardIsCurrent: true, agentTree: populatedTree()))
        #expect(render(model, name: "populated") != nil)
    }

    @Test func emptyTreeDraws() {
        let model = AgentTreeModel()
        model.receive(StatusSnapshot(agents: [], health: .ok, fetchedAt: Date(), boardIsCurrent: true, agentTree: .empty))
        #expect(render(model, name: "empty") != nil)
    }

    @Test func featureUnavailableStateDraws() {
        let model = AgentTreeModel()
        model.receive(StatusSnapshot(agents: [], health: .ok, fetchedAt: Date(), boardIsCurrent: true, agentTree: nil))
        #expect(render(model, name: "unavailable") != nil)
    }

    @Test func loadingStateDraws() {
        let model = AgentTreeModel()
        #expect(render(model, name: "loading") != nil)
    }

    @Test func errorNoticeDraws() {
        let model = AgentTreeModel()
        model.receive(StatusSnapshot(agents: [], health: .ok, fetchedAt: Date(), boardIsCurrent: true, agentTree: populatedTree()))
        model.errorMessage = "worker-x would create a cycle"
        #expect(render(model, name: "error-notice") != nil)
    }

    @Test func crossProjectConfirmationDraws() {
        let model = AgentTreeModel()
        model.receive(StatusSnapshot(agents: [], health: .ok, fetchedAt: Date(), boardIsCurrent: true, agentTree: populatedTree()))
        model.pendingConfirm = .init(
            child: node("worker-c"), parent: chief("chief-aptusfit"),
            message: "worker-c is in AptusFit, chief-aptusfit is in AptusFit; reports will only be typed into the chief's pane, no inbox record there. Attach anyway?"
        )
        #expect(render(model, name: "confirm-dialog") != nil)
    }
}
