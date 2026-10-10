import SwiftUI

/// The row's "⋯" overflow menu — first of its kind in AgentBar (2026-09-22); a future control
/// that needs somewhere to put secondary/housekeeping actions should follow this same shape
/// rather than invent another one. Holds whatever `RowButtons.menuItems` currently offers this
/// row: Done and/or Close pane (still routed through `AgentPanelModel.press`, so the existing
/// confirm-on-second-press flow applies unchanged — see `AgentRowView`'s `activeMenuItemSpec`,
/// which pulls a button back OUT of this menu and into its own capsule the moment it starts
/// confirming) plus Compact/Clear (straight to `MessageCardModel.sendDirect`, no confirm).
///
/// A native SwiftUI `Menu`, deliberately: low-visual-weight (a bare `ellipsis` glyph, styled like
/// `CopyIdentityButton`, not a capsule), opened only by a real click. There is no public SwiftUI
/// API to pop a `Menu` open programmatically, and this app's ←/→ + Enter keyboard scheme drives
/// row presses from `AgentPanelModel` rather than native view focus, so Enter on the highlighted
/// trigger cannot open it either — `RowActionMachine.plan` maps `.moreActions` to `.ignore` on
/// purpose. The trigger is still reachable by ←/→ (last, after Message) so its existence and
/// disabled state are visible from the keyboard, but opening it is mouse-only, same as choosing
/// any of its items already is.
///
/// **Equatable on what it shows, never on the raw tree nodes** (2026-10-10): the ~1s dashboard
/// refresh hands the row fresh `AgentTreeNode`s (status, children) even when no title changed, and
/// any body re-render rebuilds the native menu — which closed an open "Report to" submenu about a
/// second after it appeared. `menuContent` is the only input that may re-render it; the row applies
/// `.equatable()`.
struct RowMoreMenuView: View, Equatable {
    let items: [RowButtonSpec]
    let isHighlighted: Bool
    /// Who "Report to" offers (`AgentTree.reportTargets`) — the item is a submenu of these.
    var reportTargets: (chiefs: [AgentTreeNode], workers: [AgentTreeNode]) = ([], [])
    let onSelect: (RowButton) -> Void
    var onReportTo: (String) -> Void = { _ in }

    /// Everything the open menu displays — what `==` compares (closures are re-made every render).
    struct Content: Equatable {
        let items: [RowButtonSpec]
        let isHighlighted: Bool
        let chiefTargets: [Target]
        let workerTargets: [Target]
    }

    struct Target: Equatable, Identifiable {
        let id: String
        let title: String
    }

    nonisolated var menuContent: Content {
        Content(
            items: items, isHighlighted: isHighlighted,
            chiefTargets: reportTargets.chiefs.map(Self.target), workerTargets: reportTargets.workers.map(Self.target)
        )
    }

    nonisolated static func == (lhs: RowMoreMenuView, rhs: RowMoreMenuView) -> Bool { lhs.menuContent == rhs.menuContent }

    var body: some View {
        Menu {
            ForEach(items, id: \.button.title) { spec in
                if spec.button == .reportTo {
                    reportToSubmenu
                } else {
                    Button(spec.label) { onSelect(spec.button) }
                        .disabled(!spec.isEnabled)
                        .help(spec.disabledReason ?? "")   // same "why" tooltip a disabled capsule gives via RowActionButtonView
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11))   // matches CopyIdentityButton's icon exactly (regular weight)
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .overlay(Circle().strokeBorder(isHighlighted ? Color.accentColor : .clear, lineWidth: 1.5))
        .help("More actions")
        .accessibilityLabel("More actions")
    }

    private var reportToSubmenu: some View {
        let content = menuContent
        return Menu("Report to") {
            if content.chiefTargets.isEmpty && content.workerTargets.isEmpty {
                Button("No one to report to") {}.disabled(true)
            }
            if !content.chiefTargets.isEmpty {
                Section("Chiefs") { targetButtons(content.chiefTargets) }
            }
            if !content.workerTargets.isEmpty {
                Section("Workers") { targetButtons(content.workerTargets) }
            }
        }
    }

    private func targetButtons(_ targets: [Target]) -> some View {
        ForEach(targets) { target in
            Button(target.title) { onReportTo(target.id) }
        }
    }

    nonisolated private static func target(_ node: AgentTreeNode) -> Target { Target(id: node.id, title: targetTitle(node)) }

    /// "label · project" plus " · Air" when it runs there — enough to tell same-named agents apart.
    nonisolated static func targetTitle(_ node: AgentTreeNode) -> String {
        ([node.label, node.project] + [node.machineBadge].compactMap { $0 }).joined(separator: " · ")
    }
}
