import SwiftUI

/// One row: a chief, or a worker (in Parent-gone, under a chief, or Unassigned). Selectable; a
/// worker row is draggable onto a chief row and carries the indent/outdent/detach context menu — a
/// chief row accepts drops but is never itself draggable (two-level rule).
struct AgentTreeRowView: View {
    let node: AgentTreeNode
    /// 0 for a chief or an unassigned/parent-gone worker; 1 for a worker indented under its chief.
    let indent: Int
    @ObservedObject var model: AgentTreeModel
    var isChiefRow: Bool = false
    /// Set only in the Parent-gone section: whose pane it used to report to.
    var lostParentLabel: String? = nil

    @State private var isDropTargeted = false

    var body: some View {
        HStack(spacing: 8) {
            statusDot
            VStack(alignment: .leading, spacing: 2) {
                Text(node.label)
                    .font(.system(size: 13, weight: isChiefRow ? .semibold : .regular))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let badge = node.machineBadge, !isChiefRow {
                MachineBadgeView(text: badge)
            }
            if node.crossProject {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .help("This worker's project differs from its chief's")
            }
        }
        .padding(.leading, CGFloat(indent) * 20)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .tag(node.id)
        .background(isDropTargeted ? Color.accentColor.opacity(0.15) : Color.clear)
        .modifier(WorkerDragSource(node: node, isChief: isChiefRow))
        .modifier(ChiefDropTarget(node: node, isChief: isChiefRow, model: model, isTargeted: $isDropTargeted))
        .contextMenu { contextMenuItems }
    }

    private var statusDot: some View {
        Circle()
            .fill(node.alive ? Color.green : Color.secondary.opacity(0.4))
            .frame(width: 6, height: 6)
    }

    private var subtitle: String {
        var parts: [String] = []
        if !isChiefRow, !node.project.isEmpty { parts.append(node.project) }
        if let status = node.status, !status.isEmpty { parts.append(status) }
        if let lostParentLabel { parts.append("was reporting to \(lostParentLabel)") }
        return parts.isEmpty ? " " : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        if isChiefRow {
            Text("Chief — supervises the rows indented beneath it")
        } else {
            Button(indentMenuLabel) { select(); model.indentSelected() }
            Button("Move to Unassigned (Outdent)  ⌘[") { select(); model.outdentSelected() }
            Button("Detach — stop reporting  ⌘⌫") { select(); model.outdentSelected() }
        }
    }

    /// Parent-gone rows have nothing above them to indent under (that section is always first) —
    /// ⌘] instead finds/attaches the live chief for the same project, or asks. Different enough from
    /// "nearest chief above" that the menu text should say so.
    private var indentMenuLabel: String {
        lostParentLabel != nil ? "Indent — attach to its chief  ⌘]" : "Indent under nearest chief above  ⌘]"
    }

    /// The context menu can open on a row that isn't the List's current selection (e.g. a
    /// right-click with no prior click); make it the target so Indent/Outdent act on the row the
    /// menu was actually opened on, not a stale selection.
    private func select() { model.selectedNodeID = node.id }
}

/// A worker row can be dragged onto a chief row; a chief row cannot be dragged at all.
private struct WorkerDragSource: ViewModifier {
    let node: AgentTreeNode
    let isChief: Bool

    func body(content: Content) -> some View {
        if isChief {
            content
        } else {
            content.draggable(node.id)
        }
    }
}

/// Only a chief row accepts a drop; dropping a worker's id onto one attaches it there.
private struct ChiefDropTarget: ViewModifier {
    let node: AgentTreeNode
    let isChief: Bool
    @ObservedObject var model: AgentTreeModel
    @Binding var isTargeted: Bool

    func body(content: Content) -> some View {
        if isChief {
            content.dropDestination(for: String.self) { items, _ in
                guard let childID = items.first, let tree = model.tree, let child = tree.node(withID: childID) else { return false }
                model.attach(child: child, to: node)
                return true
            } isTargeted: { isTargeted = $0 }
        } else {
            content
        }
    }
}

/// "Air" for a node on the `air-m1` machine; the feature brief calls for nothing shown for local.
struct MachineBadgeView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
            .foregroundStyle(.secondary)
    }
}
