import Foundation

/// A button on an agent row. Done and Close pane talk to the dashboard
/// (`sessionAction`); Park and Unpark are local (`TriageState`); Answer opens
/// the answer card of a blocked question, Review opens the card of a permission box
/// (approve or deny), and Open terminal switches to the
/// agent (the way out for a blocker the panel cannot answer). Message opens the card
/// that types a line into a Claude agent that is not asking anything. Compact and Clear
/// type `/compact` / `/clear` straight through the Message pipeline (no card, no validator —
/// see `RowButtons.menuItems`). Done, Close pane, Compact and Clear never appear as their own
/// capsule; they live inside the `.moreActions` (⋯) menu (`RowMoreMenuView`), which is what
/// actually shows in the row's button strip and the ←/→ keyboard order.
enum RowButton: Equatable, Sendable {
    case answer
    case review
    case openTerminal
    case done
    case park
    case unpark
    /// Opens/closes the pane peek for this row — the button form of the old Space shortcut
    /// (which only fired with an empty search box; this works regardless).
    case peek
    case closePane
    case message
    case compact
    case clear
    /// Attaches this row to a chief — the ⋯ menu's equivalent of ⌘] (`AgentTreeModel.indentSelected`):
    /// nearest chief above in display order, or a picker if ambiguous. See `TreeRowActions`.
    case reportTo
    /// Detaches this row to Unassigned — the ⋯ menu's equivalent of ⌘[ / ⌘⌫.
    case stopReporting
    /// The ⋯ trigger that opens the overflow menu (Done / Close pane / Compact / Clear / Report to… / Stop reporting).
    case moreActions

    var title: String {
        switch self {
        case .answer: "Answer"
        case .review: "Review"
        case .openTerminal: "Open terminal"
        case .done: "Done"
        case .park: "Park"
        case .unpark: "Unpark"
        case .peek: "Peek"
        case .closePane: "Close pane"
        case .message: "Message"
        case .compact: "Compact"
        case .clear: "Clear"
        case .reportTo: "Report to…"
        case .stopReporting: "Stop reporting"
        case .moreActions: "More actions"
        }
    }

    /// The dashboard request behind the button; nil for the local ones.
    /// The way out of a blocked agent: drawn red, the colour of "needs you".
    var isBlockedAction: Bool {
        self == .answer || self == .review || self == .openTerminal
    }

    var sessionAction: SessionActionKind? {
        switch self {
        case .done: .stop
        case .closePane: .close
        case .answer, .review, .openTerminal, .park, .unpark, .peek, .message, .compact, .clear, .reportTo, .stopReporting, .moreActions: nil
        }
    }
}

/// One button as a row offers it: shown always, usable unless it has a reason not to be.
struct RowButtonSpec: Equatable, Sendable {
    let button: RowButton
    /// Why the button cannot be pressed (the dashboard's words); nil when usable.
    let disabledReason: String?

    var isEnabled: Bool { disabledReason == nil }

    /// The label on the row: an Answer that cannot be pressed yet says why in one word.
    var label: String {
        button == .answer && disabledReason == RowButtons.readingOptionsReason ? "Reading…" : button.title
    }
}

/// Which buttons a row shows, in left-to-right order, and what its overflow menu holds. Pure.
enum RowButtons {
    static let missingRowIdReason = "The dashboard did not identify this agent."
    static let refusedFallbackReason = "The dashboard refuses this right now."
    static let readingOptionsReason = "The agent's options are still being read (a few seconds). Open its terminal meanwhile."

    /// The row's capsule strip, left to right, ending in the ⋯ trigger when it has anything to
    /// show. Done and Close pane are never in this list — see `menuItems(for:)`.
    static func available(for agent: AgentSnapshot) -> [RowButtonSpec] {
        switch agent.section {
        case .needsYou:
            needsYouButtons(for: agent)
        case .parked:
            [RowButtonSpec(button: .unpark, disabledReason: nil), RowButtonSpec(button: .peek, disabledReason: nil)]
                + messageButton(for: agent) + moreActionsButton(for: agent)
        case .ended where agent.actions.close.isEnabled:
            moreActionsButton(for: agent)
        case .working:
            messageButton(for: agent) + moreActionsButton(for: agent)
        case .ended, .sleeping:
            []
        }
    }

    /// The ⋯ menu's own items for this row: Done and/or Close pane (whichever this row would have
    /// offered as a loose button before the menu existed) plus Compact/Clear when the row is
    /// message-eligible. Independent of `available(for:)` so a menu-item press (`AgentPanelModel.press`)
    /// can be authorized even though the item itself never appears in the capsule strip.
    static func menuItems(for agent: AgentSnapshot) -> [RowButtonSpec] {
        switch agent.section {
        case .needsYou where agent.blockedOnYou == nil:
            [spec(.done, for: agent)] + quickCommandItems(for: agent)
        case .parked:
            [spec(.done, for: agent)] + quickCommandItems(for: agent)
        case .ended where agent.actions.close.isEnabled:
            [spec(.closePane, for: agent)]
        case .working:
            quickCommandItems(for: agent)
        default:
            []
        }
    }

    /// Whether `button` is one this row currently allows pressing right now — whichever list it
    /// lives in, the capsule strip (`available`) or the ⋯ menu (`menuItems`). `AgentPanelModel.press`
    /// gates every press through this, so a menu selection is authorized the same way a capsule tap is.
    static func isPressable(_ button: RowButton, on agent: AgentSnapshot) -> Bool {
        if let spec = available(for: agent).first(where: { $0.button == button }) { return spec.isEnabled }
        if let spec = menuItems(for: agent).first(where: { $0.button == button }) { return spec.isEnabled }
        return false
    }

    /// Message, last so the existing keyboard order (→ lands on the ⋯ trigger) is unchanged. Only a live
    /// Claude agent (the dashboard's permission/question guard is blind to other CLIs, so a
    /// message could answer a box it cannot see) that the dashboard can address by row, and that
    /// is not asking anything (a parked row that is still blocked stays "just parked").
    private static func messageButton(for agent: AgentSnapshot) -> [RowButtonSpec] {
        isMessageEligible(agent) ? [RowButtonSpec(button: .message, disabledReason: nil)] : []
    }

    /// Same eligibility gate as `messageButton` — Compact/Clear are typed through the same
    /// Message pipeline (`MessageCardModel.sendDirect`), so a row that cannot take a message
    /// cannot take these either.
    private static func isMessageEligible(_ agent: AgentSnapshot) -> Bool {
        agent.blocker == nil && agent.rowId != nil && agent.canFocus && agent.hasHookData && agent.paneId?.isEmpty == false
    }

    private static func quickCommandItems(for agent: AgentSnapshot) -> [RowButtonSpec] {
        guard isMessageEligible(agent) else { return [] }
        return [RowButtonSpec(button: .compact, disabledReason: nil), RowButtonSpec(button: .clear, disabledReason: nil)]
    }

    /// The ⋯ trigger itself: shown only while at least one of its items is actually usable (never a
    /// menu that opens onto nothing but a disabled row — the same rule `usableButtons` already
    /// applies to a disabled Done/Close pane today).
    private static func moreActionsButton(for agent: AgentSnapshot) -> [RowButtonSpec] {
        menuItems(for: agent).contains(where: \.isEnabled) ? [RowButtonSpec(button: .moreActions, disabledReason: nil)] : []
    }

    /// A blocked agent is cleared by answering it (or in its terminal), so it
    /// offers that in place of Done; Park stays for setting it aside.
    private static func needsYouButtons(for agent: AgentSnapshot) -> [RowButtonSpec] {
        let park = RowButtonSpec(button: .park, disabledReason: nil)
        let peek = RowButtonSpec(button: .peek, disabledReason: nil)
        switch agent.blockedOnYou {
        case .question?: return [RowButtonSpec(button: .answer, disabledReason: nil), peek, park]
        case .questionLoading?: return [RowButtonSpec(button: .answer, disabledReason: readingOptionsReason), peek, park]
        case .permissionReview?: return [RowButtonSpec(button: .review, disabledReason: nil), peek, park]
        case .questionNotAnswerable?, .permission?: return [RowButtonSpec(button: .openTerminal, disabledReason: nil), peek, park]
        case nil: return [peek, park] + messageButton(for: agent) + moreActionsButton(for: agent)
        }
    }

    /// The buttons the keyboard can land on: the capsule strip only (the ⋯ trigger is a stop, not
    /// a way into its own items — see `RowMoreMenuView`'s doc comment for why).
    static func usableButtons(for agent: AgentSnapshot) -> [RowButton] {
        available(for: agent).filter(\.isEnabled).map(\.button)
    }

    private static func spec(_ button: RowButton, for agent: AgentSnapshot) -> RowButtonSpec {
        guard let kind = button.sessionAction else { return RowButtonSpec(button: button, disabledReason: nil) }
        guard agent.rowId != nil else { return RowButtonSpec(button: button, disabledReason: missingRowIdReason) }
        let availability = agent.actions.availability(of: kind)
        guard availability.isEnabled else {
            return RowButtonSpec(
                button: button,
                disabledReason: RowActionText.plainReason(availability.reason) ?? refusedFallbackReason
            )
        }
        return RowButtonSpec(button: button, disabledReason: nil)
    }
}

/// ←/→ across a row's buttons. Pure.
enum RowButtonHighlight {
    /// Moves one button (+1 right, -1 left) among `buttons`. From nothing
    /// highlighted, right lands on the first and left stays put; right at the
    /// last button stays there; left off the first un-highlights (nil).
    static func moved(from current: RowButton?, by step: Int, in buttons: [RowButton]) -> RowButton? {
        guard !buttons.isEmpty else { return nil }
        guard let current, let index = buttons.firstIndex(of: current) else {
            return step > 0 ? buttons.first : nil
        }
        let target = index + step
        if target < 0 { return nil }
        return buttons[min(target, buttons.count - 1)]
    }

    /// The highlight after the row's buttons changed under it: kept while that button still exists.
    static func reconciled(_ current: RowButton?, in buttons: [RowButton]) -> RowButton? {
        guard let current, buttons.contains(current) else { return nil }
        return current
    }
}
