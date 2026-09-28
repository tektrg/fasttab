import SwiftUI

/// Panel content: the list or a status message, the optional stale-board note, then the search
/// field and the footer (a failure notice floats above it). Total height is dictated by
/// `AgentPanelMetrics`. Tab-tagged (`AgentPanelModel.taggedAgentID`): the list/status message and the
/// board note are both hidden — the target is already chosen (shown as a chip in the search field
/// itself), so there's nothing left to pick from, and showing it anyway would just be clutter.
struct AgentPanelView: View {
    @ObservedObject var model: AgentPanelModel
    let onClose: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Search sits at the bottom, just above the footer: the panel is anchored to the screen's
            // bottom edge and grows upward (`AgentPanelPlacement`), so the box never moves as the list filters.
            VStack(spacing: 0) {
                bodyContent
                if model.presentation.showsBoardNote, model.taggedAgentID == nil {
                    BoardNoteView()
                }
            }
            .overlay(alignment: .bottom) { failureNotice }
            Divider()
            SearchFieldView(model: model, onClose: onClose)
            PanelFooterView(
                notice: model.footerNotice,
                hintContext: .init(
                    isPeeking: model.peek != nil,
                    hasHighlightedButton: model.highlightedButton != nil,
                    searchIsEmpty: model.query.isEmpty,
                    answerMode: model.answer.card?.hintMode,
                    permissionMode: model.permission.card?.hintMode,
                    messageMode: model.message.card?.hintMode,
                    hasDismissibleNotice: model.footerNotice?.isDismissible == true,
                    routingMode: model.routingState.map { switch $0 {
                        case .loading: .loading
                        case .confirming: .confirming
                        case .confirmingPersona(let pick): pick.effect.refusesDelivery ? .confirmingPersonaRefusal : .confirmingPersona
                        case .startingPersona: .startingPersona
                    } },
                    isTagged: model.taggedAgentID != nil
                ),
                onOpenSettings: onOpenSettings
            )
        }
        .frame(width: AgentPanelMetrics.width)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.12)))
        .confirmationDialog(
            "Attach across projects?",
            isPresented: Binding(get: { model.treeModel.pendingConfirm != nil }, set: { if !$0 { model.treeModel.cancelPendingAttach() } }),
            presenting: model.treeModel.pendingConfirm
        ) { pending in
            Button("Attach anyway") { model.treeModel.confirmPendingAttach() }
            Button("Cancel", role: .cancel) { model.treeModel.cancelPendingAttach() }
        } message: { pending in
            Text(pending.message)
        }
        .confirmationDialog(
            "Attach to which chief?",
            isPresented: Binding(get: { model.treeModel.pendingChiefPicker != nil }, set: { if !$0 { model.treeModel.cancelChiefPicker() } }),
            presenting: model.treeModel.pendingChiefPicker
        ) { picker in
            ForEach(picker.candidates) { candidate in
                Button(chiefPickerLabel(candidate)) { model.treeModel.chooseChiefForPendingIndent(candidate) }
            }
            Button("Cancel", role: .cancel) { model.treeModel.cancelChiefPicker() }
        } message: { picker in
            Text("\(picker.child.label) has no chief above it to attach to — pick one.")
        }
        // Hidden, not visible controls — `.keyboardShortcut` fires window-wide once the panel is
        // key, regardless of which control (if any) has first responder (same technique the old
        // Agent Hierarchy window used; List row selection keeps this working without a competing
        // handler since nothing else claims ⌘]/⌘[/⌘⌫).
        .background {
            Group {
                Button("Report to nearest chief", action: model.treeModel.indentSelected).keyboardShortcut("]", modifiers: .command)
                Button("Stop reporting (Unassigned)", action: model.treeModel.outdentSelected).keyboardShortcut("[", modifiers: .command)
                // Only while the search is empty — otherwise ⌘⌫ belongs to the text field (delete to line start).
                if model.query.isEmpty {
                    Button("Stop reporting", action: model.treeModel.outdentSelected).keyboardShortcut(.delete, modifiers: .command)
                }
            }
            .hidden()
        }
    }

    /// A candidate row in the chief picker: project plus a machine badge, so same-named chiefs on
    /// different machines/projects are still distinguishable. Same wording the old tree view used.
    private func chiefPickerLabel(_ chief: AgentTreeNode) -> String {
        let project = chief.project.isEmpty ? chief.label : chief.project
        return chief.machineBadge.map { "\(project) (\($0))" } ?? project
    }

    /// A failure stays over the bottom of the body, above the search field, until dismissed.
    @ViewBuilder
    private var failureNotice: some View {
        if let notice = model.footerNotice, notice.isDismissible {
            FooterNoticeView(notice: notice) { model.dismissFooterNotice() }
        }
    }

    @ViewBuilder
    private var bodyContent: some View {
        if model.answer.isOpen {
            AnswerCardView(
                answer: model.answer,
                bodyHeight: AgentPanelMetrics.fullBodyHeight(
                    maxListHeight: AgentPanelMetrics.maxListHeight(visibleRows: model.listSettings.maxVisibleRows)
                ),
                copiedAgentID: model.copier.copiedAgentID,
                onCopy: { model.copyOpenCardIdentity() },
                onOpen: { model.openCardAgent() }
            )
        } else if model.permission.isOpen {
            PermissionCardView(
                permission: model.permission,
                bodyHeight: AgentPanelMetrics.fullBodyHeight(
                    maxListHeight: AgentPanelMetrics.maxListHeight(visibleRows: model.listSettings.maxVisibleRows)
                ),
                copiedAgentID: model.copier.copiedAgentID,
                onCopy: { model.copyOpenCardIdentity() },
                onOpen: { model.openCardAgent() }
            )
        } else if model.message.isOpen {
            MessageCardView(
                message: model.message,
                bodyHeight: AgentPanelMetrics.fullBodyHeight(
                    maxListHeight: AgentPanelMetrics.maxListHeight(visibleRows: model.listSettings.maxVisibleRows)
                ),
                copiedAgentID: model.copier.copiedAgentID,
                onCopy: { model.copyOpenCardIdentity() },
                onOpen: { model.openCardAgent() }
            )
        } else if let peek = model.peek {
            PanePeekView(
                peek: peek,
                bodyHeight: AgentPanelMetrics.peekBodyHeight(
                    maxListHeight: AgentPanelMetrics.maxListHeight(visibleRows: model.listSettings.maxVisibleRows)
                ),
                onOpen: { model.openPeekAgent() }
            )
        } else if model.taggedAgentID != nil {
            // Composing: the target is already chosen (the chip in the search field), so the
            // list/status below has nothing left to contribute — matches
            // `AgentPanelMetrics.height(isComposing:)` collapsing this area to zero height.
            EmptyView()
        } else if model.presentation.state == .list {
            AgentListView(
                model: model,
                rows: model.presentation.rows,
                fetchedAt: model.snapshot?.fetchedAt ?? Date()
            )
        } else {
            StatusMessageView(state: model.presentation.state, dashboardAddress: model.dashboardAddress)
        }
    }
}
