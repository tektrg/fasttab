import SwiftUI
import IndieCommandBar

/// One agent row. The selected row (hover or keyboard) reveals its buttons in
/// place of the age; a row waiting for a confirming press shows why, in red.
struct AgentRowView: View {
    let agent: AgentSnapshot
    /// Where this row sits within its status section (`.flat` while searching, or before the tree
    /// has loaded) — drives indentation and the chief/cross-project/lost-parent decorations. See
    /// `AgentListGrouping`.
    var nesting: AgentRowNesting = .flat
    let isSelected: Bool
    let fetchedAt: Date
    var actionState: RowActionState?
    /// The agent's answer or decision is on its way: a spinner with these words replaces the buttons.
    var sendingLabel: String?
    /// A message to this agent just went: this ("Message sent" / "Message queued") replaces the buttons for a few seconds.
    var sentLabel: String?
    var highlightedButton: RowButton?
    /// This row's details were just copied (its copy icon shows a check).
    var isCopied = false
    /// What Shift+Return routing has sent this agent, newest first; only the user clears one.
    var routedNotes: [RoutedNote] = []
    /// "Report to…"/"Stop reporting" for this row (`TreeRowActions`), merged into the ⋯ menu
    /// alongside Done/Close pane/Compact/Clear.
    var treeMenuItems: [RowButtonSpec] = []
    var reportTargets: (chiefs: [AgentTreeNode], workers: [AgentTreeNode]) = ([], [])
    var onPress: (RowButton) -> Void = { _ in }
    var onReportTo: (String) -> Void = { _ in }
    var onCopy: () -> Void = {}
    var onClearRoutedNote: (UUID) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(agent.section.dotColor)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 3) {
                titleLine
                detailLine
            }
        }
        .padding(.leading, indent)
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .frame(minHeight: AgentPanelMetrics.rowHeight)   // grows with a wrapped status line
        .commandBarRowHighlight(isSelected: isSelected)   // the shared selected-row look
        .padding(.horizontal, 10)
        .opacity(dimming)
        .contentShape(Rectangle())
    }

    /// Only a worker nested under its chief indents — a chief and every loose row (including
    /// Parent-gone) sit flush left, same as the old tree view's rule.
    private var indent: CGFloat {
        if case .child = nesting { return 20 }
        return 0
    }

    private var titleLine: some View {
        HStack(spacing: 8) {
            Text(agent.label)
                .font(.avenir(size: 14, weight: .semibold))
                .lineLimit(1)
            if let project = agent.projectName {
                Text(project)
                    .font(.avenir(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let hostBadge = agent.host.badgeText { MachineBadgeView(text: hostBadge) }
            accountTags
            nestingDecorations
            Spacer(minLength: 8)
            if let sendingLabel {
                sendingIndicator(sendingLabel)
            } else if let sentLabel {
                sentIndicator(sentLabel)
            } else {
                // Only on the hovered / selected row, BEFORE the buttons: the red button stays at the far right.
                if isSelected {
                    CopyIdentityButton(isCopied: isCopied, onCopy: onCopy)
                }
                if showsButtons {
                    buttonStrip
                } else if agent.section != .sleeping {   // a sleeping row says its age in the status line
                    AgentAgeView(agent: agent, fetchedAt: fetchedAt)
                }
            }
        }
    }

    /// "limit" when the pane shows a Claude account wall; the account's name when it is not the default one.
    @ViewBuilder
    private var accountTags: some View {
        if agent.limitWall {
            MachineBadgeView(text: "limit", tint: .red)
                .help("This Claude account hit its limit. ⋯ › Resume on next account")
        }
        if let accountLabel = agent.accountLabel { MachineBadgeView(text: accountLabel) }
    }

    private func sendingIndicator(_ label: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(label)
                .font(.avenir(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .fixedSize()
        .accessibilityLabel(label)
    }

    private func sentIndicator(_ label: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark")
                .font(.avenir(size: 10, weight: .semibold))
                .foregroundStyle(Color.green)
            Text(label)
                .font(.avenir(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .fixedSize()
        .accessibilityLabel(label)
    }

    /// A chief's "N needs you" hint, a worker's cross-project marker, and either row's "Air"
    /// machine badge — the decorations `AgentListGrouping`'s nesting carries per row.
    @ViewBuilder
    private var nestingDecorations: some View {
        switch nesting {
        case .chief(let needsYouHint, let machineBadge):
            if needsYouHint > 0 {
                Text("\(needsYouHint) needs you")
                    .font(.avenir(size: 10, weight: .semibold))
                    .foregroundStyle(Color.red)
            }
            if let machineBadge { MachineBadgeView(text: machineBadge) }
        case .child(let crossProject, let machineBadge):
            if crossProject {
                Image(systemName: "arrow.triangle.branch")
                    .font(.avenir(size: 10))
                    .foregroundStyle(.orange)
                    .help("This worker's project differs from its chief's")
            }
            if let machineBadge { MachineBadgeView(text: machineBadge) }
        case .loose(_, let machineBadge):
            if let machineBadge { MachineBadgeView(text: machineBadge) }
        case .flat:
            EmptyView()
        }
    }

    /// Everything this row offers (the full list the keyboard and the model gate on).
    private var buttons: [RowButtonSpec] {
        var specs = RowButtons.available(for: agent)
        guard !menuItems.isEmpty, !specs.contains(where: { $0.button == .moreActions }) else { return specs }
        specs.append(RowButtonSpec(button: .moreActions, disabledReason: nil))
        return specs
    }

    /// The ⋯ menu: the text buttons that no longer draw as capsules (Peek, Park, Message…), then the
    /// menu's own items (Done, Compact…), then the tree items.
    private var menuItems: [RowButtonSpec] {
        RowButtons.movedIntoMenu(RowButtons.available(for: agent)) + RowButtons.menuItems(for: agent) + treeMenuItems
    }

    /// Done/Close pane live in the ⋯ menu normally, but a press that needs a second look (or is
    /// mid-flight, or just finished) must not vanish the moment the menu closes: this pulls that
    /// one item back out so it re-shows as its own capsule — the same "Confirm?" / spinner / "Done"
    /// capsule the row always drew, in place of the ⋯ trigger — for exactly as long as
    /// `actionState` is about it. The safety confirmation is never skipped; it just moves.
    private var activeMenuItemSpec: RowButtonSpec? {
        guard let button = actionState?.button, button == .done || button == .closePane else { return nil }
        return menuItems.first { $0.button == button }
    }

    /// Buttons show on the selected row, and stay while a press is being settled.
    /// A blocked row always shows its red button, so it cannot be missed.
    /// Blocked, or its turn ended on a question (wrap_up): the red button shows even unselected.
    private var showsQuestionButton: Bool {
        agent.blockedOnYou != nil || (agent.section == .needsYou && agent.wrapUpQuestion != nil)
    }

    private var showsButtons: Bool {
        !visibleButtons.isEmpty && (isSelected || actionState != nil || showsQuestionButton)
    }

    /// Selected (or settling): every button, with a busy/confirming/just-finished menu item
    /// (`activeMenuItemSpec`) swapped in for the ⋯ trigger. Otherwise only the blocked row's red one.
    private var visibleButtons: [RowButtonSpec] {
        // Only the red blocker button and ⋯ draw; a button the keyboard is on (or that is mid-press)
        // is drawn too, so it never acts unseen. Everything else is in the ⋯ menu.
        var keeping: Set<RowButton> = []
        if let highlightedButton { keeping.insert(highlightedButton) }
        if let pressed = actionState?.button { keeping.insert(pressed) }
        let strip = RowButtons.stripSpecs(buttons, keeping: keeping)
        let base = isSelected || actionState != nil ? strip : strip.filter { showsQuestionButton && $0.isBlockedAction }
        guard let activeMenuItemSpec else { return base }
        return base.map { $0.button == .moreActions ? activeMenuItemSpec : $0 }
    }

    /// Drawn inline (no backing, no fade) through the shared row-button overlay.
    private var buttonStrip: some View {
        RowActionOverlay(
            isSelected: isSelected, isHovering: false, leadingFadeWidth: 0, trailingPadding: 0,
            spacing: 6, showsBackground: false
        ) {
            ForEach(RowButtons.drawingOrder(visibleButtons), id: \.button.title) { spec in
                if spec.button == .moreActions {
                    RowMoreMenuView(
                        items: menuItems,
                        isHighlighted: highlightedButton == .moreActions,
                        reportTargets: reportTargets,
                        onSelect: { onPress($0) },
                        onReportTo: onReportTo
                    )
                    .equatable()   // a refresh with the same menu text must not rebuild an open menu
                } else {
                    RowActionButtonView(
                        spec: spec,
                        state: actionState,
                        isHighlighted: highlightedButton == spec.button,
                        onPress: { onPress(spec.button) }
                    )
                }
            }
        }
    }

    private var detailLine: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(detailText)
                .font(.avenir(size: 12))
                .foregroundStyle(isConfirming ? Color.red : .secondary)
                .fixedSize(horizontal: false, vertical: true)   // wraps, never cut with an ellipsis
            Spacer(minLength: 8)
            if !routedNotes.isEmpty {
                RoutedNoteBadgeView(notes: routedNotes, onClear: onClearRoutedNote)
            }
            if agent.hasUnpushedCommits {
                UnpushedBadgeView(detail: agent.unpushedText)
            }
        }
    }

    private var isConfirming: Bool {
        if case .confirming? = actionState { return true }
        return false
    }

    /// The status line, or the stake and "Confirm?" while a press awaits its second press, or (a
    /// Parent-gone row) who it used to report to — the tree view's own wording.
    private var detailText: String {
        if case .confirming(let button, let reason)? = actionState, let kind = button.sessionAction {
            return RowActionText.confirmPrompt(kind: kind, reason: reason)
        }
        if case .loose(let lostParentLabel?, _) = nesting {
            return "\(agent.statusText) · was reporting to \(lostParentLabel)"
        }
        return agent.statusText
    }

    /// Ended rows are clearly out of play (unless their pane is still open and
    /// waiting to be closed); sleeping sessions are greyed (not running, Enter wakes one) —
    /// except the selected one, whose Open in Claude button must not read as disabled;
    /// best-guess non-Claude panes are a shade quieter (`isBestGuessNonClaudePane`); a Claude agent on another
    /// machine is not, though it has no hook data.
    private var dimming: Double { Self.dimming(of: agent, isSelected: isSelected) }

    static func dimming(of agent: AgentSnapshot, isSelected: Bool) -> Double {
        if agent.section == .ended { return agent.canFocus ? 0.85 : 0.45 }
        if agent.section == .sleeping { return isSelected ? 1 : 0.55 }
        return agent.isBestGuessNonClaudePane ? 0.7 : 1
    }
}
