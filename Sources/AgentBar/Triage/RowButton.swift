import Foundation

/// A button on an agent row. Done and Close pane talk to the dashboard
/// (`sessionAction`); Park and Unpark are local (`TriageState`); Answer opens
/// the answer card of a blocked question, Review opens the card of a permission box
/// (approve or deny), and Open terminal switches to the
/// agent (the way out for a blocker the panel cannot answer).
enum RowButton: Equatable, Sendable {
    case answer
    case review
    case openTerminal
    case done
    case park
    case unpark
    case closePane

    var title: String {
        switch self {
        case .answer: "Answer"
        case .review: "Review"
        case .openTerminal: "Open terminal"
        case .done: "Done"
        case .park: "Park"
        case .unpark: "Unpark"
        case .closePane: "Close pane"
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
        case .answer, .review, .openTerminal, .park, .unpark: nil
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

/// Which buttons a row shows, in left-to-right order. Pure.
enum RowButtons {
    static let missingRowIdReason = "The dashboard did not identify this agent."
    static let refusedFallbackReason = "The dashboard refuses this right now."
    static let readingOptionsReason = "The agent's options are still being read (a few seconds). Open its terminal meanwhile."

    static func available(for agent: AgentSnapshot) -> [RowButtonSpec] {
        switch agent.section {
        case .needsYou:
            needsYouButtons(for: agent)
        case .parked:
            [RowButtonSpec(button: .unpark, disabledReason: nil), spec(.done, for: agent)]
        case .ended where agent.actions.close.isEnabled:
            [spec(.closePane, for: agent)]
        case .working, .ended:
            []
        }
    }

    /// A blocked agent is cleared by answering it (or in its terminal), so it
    /// offers that in place of Done; Park stays for setting it aside.
    private static func needsYouButtons(for agent: AgentSnapshot) -> [RowButtonSpec] {
        let park = RowButtonSpec(button: .park, disabledReason: nil)
        switch agent.blockedOnYou {
        case .question?: return [RowButtonSpec(button: .answer, disabledReason: nil), park]
        case .questionLoading?: return [RowButtonSpec(button: .answer, disabledReason: readingOptionsReason), park]
        case .permissionReview?: return [RowButtonSpec(button: .review, disabledReason: nil), park]
        case .questionNotAnswerable?, .permission?: return [RowButtonSpec(button: .openTerminal, disabledReason: nil), park]
        case nil: return [spec(.done, for: agent), park]
        }
    }

    /// The buttons the keyboard can land on.
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
