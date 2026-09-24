import Foundation

/// State and actions for the Agent Hierarchy window: who reports to whom, and edits to it
/// (attach/detach). Deliberately separate from `AgentTreeView` — no SwiftUI import here — so the
/// same logic can back a future web-dashboard UI of the same tree (PO decision, see the feature
/// brief). One level of scope down from `AgentPanelModel`'s own state/view split.
@MainActor
final class AgentTreeModel: ObservableObject {
    /// A 409 cross-project attach, waiting on the user's "Attach anyway?" before it retries with
    /// `confirmCrossProject: true`.
    struct PendingCrossProjectConfirm: Equatable {
        let child: AgentTreeNode
        let parent: AgentTreeNode
        /// The server's own words (see `AttachOutcome.needsConfirm`).
        let message: String
    }

    /// A Parent-gone row's Indent (⌘]) with no unambiguous live chief to attach to — see
    /// `indentParentGoneRow`. `candidates` is every live chief, same-project ones first.
    struct PendingChiefPicker: Equatable {
        let child: AgentTreeNode
        let candidates: [AgentTreeNode]
    }

    /// Nil until the first snapshot carrying a tree arrives (or forever, on a dashboard too old to
    /// send one — see `featureUnavailable`).
    @Published private(set) var tree: AgentTree?
    /// True once a healthy snapshot has arrived with no `agentTree` field at all: an older
    /// dashboard. Distinct from `tree == nil` while still waiting for the first snapshot.
    @Published private(set) var featureUnavailable = false
    @Published private(set) var isDashboardReachable = true
    @Published var selectedNodeID: String?
    @Published var pendingConfirm: PendingCrossProjectConfirm?
    @Published var pendingChiefPicker: PendingChiefPicker?
    /// A refusal/failure from the last attach or detach; shown inline, dismissible, replaced by the
    /// next one.
    @Published var errorMessage: String?
    /// A non-fatal warning on an otherwise-successful attach (`AttachOutcome.attached(warning:)`).
    @Published var infoMessage: String?

    var editing: AgentTreeEditing?

    /// Bumped every time `receive(_:)` installs a server-authoritative tree (or clears it) — never
    /// by `attach`/`detach`'s own optimistic edits. Lets an in-flight attach/detach tell, once its
    /// `await` returns, whether a fresher snapshot already superseded the tree it optimistically
    /// edited: reverting to its own stale `previousTree` at that point would silently discard the
    /// newer server state (QA-flagged race — the SSE feed ticks every ~2s, well inside an attach's
    /// round trip).
    private var treeGeneration = 0

    init(editing: AgentTreeEditing? = nil) {
        self.editing = editing
    }

    /// Called with every status snapshot (same cadence as `AgentPanelModel.receive`, forwarded by
    /// `AgentBarCoordinator` from the one dashboard feed — this model never polls on its own).
    func receive(_ snapshot: StatusSnapshot) {
        isDashboardReachable = !snapshot.health.isDown
        guard !snapshot.health.isDown else { return }   // keep the last known tree on a blip
        if let newTree = snapshot.agentTree {
            tree = newTree
            treeGeneration += 1
            featureUnavailable = false
            if let selectedNodeID, newTree.node(withID: selectedNodeID) == nil {
                self.selectedNodeID = nil
            }
        } else {
            featureUnavailable = true
            tree = nil
            treeGeneration += 1
        }
    }

    // MARK: - Keyboard / menu actions (⌘] / ⌘[ / ⌘⌫)

    /// Attaches the selected row to the nearest chief row above it in display order — except a
    /// Parent-gone row, which has nothing above it (that section is always first): see
    /// `indentParentGoneRow`.
    func indentSelected() {
        guard let selectedNodeID, let tree, let node = tree.node(withID: selectedNodeID) else { return }
        guard !tree.isChief(selectedNodeID) else {
            errorMessage = "\(node.label) is a chief — a chief can't report to another chief (two levels only)."
            return
        }
        if tree.parentGone.contains(where: { $0.node.id == selectedNodeID }) {
            indentParentGoneRow(node, in: tree)
            return
        }
        let rows = AgentTreeDisplayOrder.flatten(tree)
        guard let target = AgentTreeDisplayOrder.nearestChief(above: selectedNodeID, in: rows) else {
            errorMessage = "No chief above \(node.label) to attach to — drag it onto a chief instead."
            return
        }
        attach(child: node, to: target)
    }

    /// A Parent-gone row structurally has no chief "above" it, so Indent instead looks for the live
    /// chief already covering its project: `chief.alive && chief.project == node.project`, preferring
    /// a sole `isChiefMode` match when more than one qualifies. Exactly one candidate attaches
    /// directly; zero or several open `pendingChiefPicker` (same-project candidates first) instead of
    /// guessing — picking a different-project chief there still goes through the normal cross-project
    /// confirm, since that's decided by the server's reply, not by this picker.
    private func indentParentGoneRow(_ node: AgentTreeNode, in tree: AgentTree) {
        let liveChiefs = tree.chiefs.filter(\.alive)
        var sameProject = liveChiefs.filter { $0.project == node.project }
        if sameProject.count > 1 {
            let chiefModeOnly = sameProject.filter(\.isChiefMode)
            if chiefModeOnly.count == 1 { sameProject = chiefModeOnly }
        }
        if sameProject.count == 1 {
            attach(child: node, to: sameProject[0])
            return
        }
        guard !liveChiefs.isEmpty else {
            errorMessage = "No live chief to attach \(node.label) to."
            return
        }
        // Partition, not `sorted(by:)`: a same-project/not comparator isn't a strict weak ordering
        // (two same-project elements are each "less than" the other), so `filter` twice instead —
        // same-project first, each half keeping the server's original relative order.
        let ordered = liveChiefs.filter { $0.project == node.project } + liveChiefs.filter { $0.project != node.project }
        pendingChiefPicker = PendingChiefPicker(child: node, candidates: ordered)
    }

    /// A choice made from `pendingChiefPicker`.
    func chooseChiefForPendingIndent(_ chief: AgentTreeNode) {
        guard let pendingChiefPicker else { return }
        self.pendingChiefPicker = nil
        attach(child: pendingChiefPicker.child, to: chief)
    }

    func cancelChiefPicker() {
        pendingChiefPicker = nil
    }

    /// Detaches the selected row to Unassigned. Also what ⌘⌫ does (explicit "stop reporting" alias
    /// for the same action — the feature brief names both, deliberately not two different effects).
    func outdentSelected() {
        guard let selectedNodeID, let tree, let node = tree.node(withID: selectedNodeID) else { return }
        guard !tree.isChief(selectedNodeID) else {
            errorMessage = "\(node.label) is a chief — chiefs aren't attached to anyone to begin with."
            return
        }
        detach(child: node)
    }

    // MARK: - Attach / detach

    /// Attaches `child` under `parent`. Optimistic: moves it locally right away for instant
    /// feedback, then reconciles with the server's reply — reverted on refusal/failure, left in
    /// place on success (the next SSE snapshot, arriving within ~2s, is authoritative either way and
    /// fully replaces `tree`, so there is nothing further to reconcile here).
    func attach(child: AgentTreeNode, to parent: AgentTreeNode, confirmCrossProject: Bool = false) {
        guard let editing else { errorMessage = "Not connected to the dashboard."; return }
        guard child.id != parent.id else { return }
        // Split from the checks below: a nil tree means "hasn't loaded yet", not "is a chief" — the
        // combined form used to report the wrong reason for the same silent no-op.
        guard let tree else {
            errorMessage = "The hierarchy hasn't loaded yet."
            return
        }
        guard !tree.isChief(child.id) else {
            errorMessage = "\(child.label) is a chief — a chief can't report to another chief (two levels only)."
            return
        }
        // Defensive: every caller (indent, drag-drop, the confirm/picker retries) should already
        // have picked an actual chief, but `movingChild` no-ops silently on a bad parent id — catch
        // it here instead, so a future caller's mistake surfaces as a message, not a quiet freeze.
        guard tree.isChief(parent.id) else {
            errorMessage = "\(parent.label) isn't a chief — pick a chief to attach \(child.label) to."
            return
        }
        errorMessage = nil
        let previousTree = tree
        let generationAtStart = treeGeneration
        self.tree = tree.movingChild(child.id, toChiefID: parent.id)
        Task {
            let outcome = await editing.attachToTree(child: child.id, parent: parent.id, confirmCrossProject: confirmCrossProject)
            // A fresh SSE snapshot may have landed (via `receive`) while this was in flight, already
            // replacing `tree` with server-authoritative state. Reverting to `previousTree` now would
            // silently throw that newer state away — only revert if nothing has superseded it.
            let stillCurrent = treeGeneration == generationAtStart
            switch outcome {
            case .attached(let warning):
                infoMessage = warning
            case .needsConfirm(let message):
                if stillCurrent { self.tree = previousTree }   // nothing happened yet: undo the optimistic move
                pendingConfirm = PendingCrossProjectConfirm(child: child, parent: parent, message: message)
            case .refused(let message), .failed(let message):
                if stillCurrent { self.tree = previousTree }
                errorMessage = message
            }
        }
    }

    /// Moves `child` to Unassigned. Same optimistic-then-reconciled shape as `attach`.
    func detach(child: AgentTreeNode) {
        guard let editing else { errorMessage = "Not connected to the dashboard."; return }
        guard let tree, !tree.isChief(child.id) else { return }
        errorMessage = nil
        let previousTree = tree
        let generationAtStart = treeGeneration
        self.tree = tree.movingChildToUnassigned(child.id)
        Task {
            if case .failed(let message) = await editing.detachFromTree(child: child.id) {
                if treeGeneration == generationAtStart { self.tree = previousTree }
                errorMessage = message
            }
        }
    }

    func confirmPendingAttach() {
        guard let pendingConfirm else { return }
        self.pendingConfirm = nil
        attach(child: pendingConfirm.child, to: pendingConfirm.parent, confirmCrossProject: true)
    }

    func cancelPendingAttach() {
        pendingConfirm = nil
    }

    func dismissError() { errorMessage = nil }
    func dismissInfo() { infoMessage = nil }
}
