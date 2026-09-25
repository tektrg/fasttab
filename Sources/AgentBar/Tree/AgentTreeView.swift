import SwiftUI

/// "Agent Hierarchy": who reports to whom, editable. Its own top-level window
/// (`AgentTreeWindowController`), reached from the menu bar item — not a mode inside the ⌥Tab
/// switcher panel. Two reasons: (1) the switcher panel is a compact, transient popup sized for a
/// handful of rows and driven by a summon/release hotkey, while this is a persistent, resizable,
/// drag-and-drop workspace for restructuring supervision — closer in shape and lifecycle to
/// Settings than to the switcher; (2) `AgentPanelModel`/`AgentPanelView`/`AgentPanelController` were
/// already mid-edit by another session while this was built, so a separate surface (new files only,
/// wired from `AgentBarCoordinator`) avoids colliding with that work. If a future pass wants it
/// folded into the panel instead, `AgentTreeModel` is already split from this view for that move.
struct AgentTreeView: View {
    @ObservedObject var model: AgentTreeModel

    static let width: CGFloat = 460
    static let height: CGFloat = 560

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 360, minHeight: 320)
        .confirmationDialog(
            "Attach across projects?",
            isPresented: Binding(get: { model.pendingConfirm != nil }, set: { if !$0 { model.cancelPendingAttach() } }),
            presenting: model.pendingConfirm
        ) { pending in
            Button("Attach anyway") { model.confirmPendingAttach() }
            Button("Cancel", role: .cancel) { model.cancelPendingAttach() }
        } message: { pending in
            Text(pending.message)
        }
        .confirmationDialog(
            "Attach to which chief?",
            isPresented: Binding(get: { model.pendingChiefPicker != nil }, set: { if !$0 { model.cancelChiefPicker() } }),
            presenting: model.pendingChiefPicker
        ) { picker in
            ForEach(picker.candidates) { candidate in
                Button(chiefPickerLabel(candidate)) { model.chooseChiefForPendingIndent(candidate) }
            }
            Button("Cancel", role: .cancel) { model.cancelChiefPicker() }
        } message: { picker in
            Text("\(picker.child.label) has no chief above it to attach to — pick one.")
        }
        // Hidden buttons, not visible controls: SwiftUI's `.keyboardShortcut` fires window-wide
        // once the window is key, regardless of which control (if any) has first responder — this
        // is how the List's own row selection keeps ⌘]/⌘[/⌘⌫ working without a competing handler.
        .background {
            Group {
                Button("Indent", action: model.indentSelected).keyboardShortcut("]", modifiers: .command)
                Button("Outdent", action: model.outdentSelected).keyboardShortcut("[", modifiers: .command)
                Button("Detach", action: model.outdentSelected).keyboardShortcut(.delete, modifiers: .command)
            }
            .hidden()
        }
    }

    private var header: some View {
        HStack {
            Text("Agent Hierarchy")
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            if !model.isDashboardReachable {
                Label("Dashboard unreachable", systemImage: "wifi.slash")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        if model.featureUnavailable {
            placeholder(systemImage: "questionmark.circle", text: "Tree needs a newer dashboard")
        } else if let tree = model.tree {
            if tree.isEmpty {
                placeholder(systemImage: "person.2.slash", text: "No agents running yet")
            } else {
                ZStack(alignment: .bottom) {
                    list(for: tree)
                    footerNotice
                }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func placeholder(systemImage: String, text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage).font(.system(size: 28)).foregroundStyle(.secondary)
            Text(text).font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func list(for tree: AgentTree) -> some View {
        List(selection: $model.selectedNodeID) {
            if !tree.parentGone.isEmpty {
                Section {
                    ForEach(tree.parentGone) { entry in
                        AgentTreeRowView(node: entry.node, indent: 0, model: model, lostParentLabel: entry.lostParentLabel)
                    }
                } header: {
                    Text("Parent gone (\(tree.parentGone.count))")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.red)
                }
            }
            ForEach(tree.chiefs) { chief in
                Section {
                    AgentTreeRowView(node: chief, indent: 0, model: model, isChiefRow: true)
                    ForEach(chief.children) { child in
                        AgentTreeRowView(node: child, indent: 1, model: model)
                    }
                } header: {
                    chiefHeader(chief)
                }
            }
            if !tree.unassigned.isEmpty {
                Section {
                    ForEach(tree.unassigned) { node in
                        AgentTreeRowView(node: node, indent: 0, model: model)
                    }
                } header: {
                    Text("Unassigned").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.sidebar)
    }

    /// A candidate row in the chief picker: project plus a machine badge, so same-named chiefs on
    /// different machines/projects are still distinguishable.
    private func chiefPickerLabel(_ chief: AgentTreeNode) -> String {
        let project = chief.project.isEmpty ? chief.label : chief.project
        return chief.machineBadge.map { "\(project) (\($0))" } ?? project
    }

    private func chiefHeader(_ chief: AgentTreeNode) -> some View {
        HStack(spacing: 6) {
            Text(chief.project.isEmpty ? chief.label : chief.project)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            if let badge = chief.machineBadge { MachineBadgeView(text: badge) }
        }
    }

    @ViewBuilder
    private var footerNotice: some View {
        if let message = model.errorMessage {
            noticeBar(message, color: .red, dismiss: model.dismissError)
        } else if let message = model.infoMessage {
            noticeBar(message, color: .orange, dismiss: model.dismissInfo)
        }
    }

    private func noticeBar(_ text: String, color: Color, dismiss: @escaping () -> Void) -> some View {
        HStack(alignment: .top) {
            Text(text).font(.system(size: 11)).foregroundStyle(color).lineLimit(3)
            Spacer()
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(.regularMaterial)
    }
}
