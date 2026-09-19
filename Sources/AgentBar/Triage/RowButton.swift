import Foundation

/// A button on an agent row. Done and Close pane talk to the dashboard
/// (`sessionAction`); Park and Unpark are local (`TriageState`).
enum RowButton: Equatable, Sendable {
    case done
    case park
    case unpark
    case closePane

    var title: String {
        switch self {
        case .done: "Done"
        case .park: "Park"
        case .unpark: "Unpark"
        case .closePane: "Close pane"
        }
    }

    /// The dashboard request behind the button; nil for the local ones.
    var sessionAction: SessionActionKind? {
        switch self {
        case .done: .stop
        case .closePane: .close
        case .park, .unpark: nil
        }
    }
}

/// One button as a row offers it: shown always, usable unless it has a reason not to be.
struct RowButtonSpec: Equatable, Sendable {
    let button: RowButton
    /// Why the button cannot be pressed (the dashboard's words); nil when usable.
    let disabledReason: String?

    var isEnabled: Bool { disabledReason == nil }
}

/// Which buttons a row shows, in left-to-right order. Pure.
enum RowButtons {
    static let missingRowIdReason = "The dashboard did not identify this agent."
    static let refusedFallbackReason = "The dashboard refuses this right now."

    static func available(for agent: AgentSnapshot) -> [RowButtonSpec] {
        switch agent.section {
        case .needsYou:
            [spec(.done, for: agent), RowButtonSpec(button: .park, disabledReason: nil)]
        case .parked:
            [RowButtonSpec(button: .unpark, disabledReason: nil), spec(.done, for: agent)]
        case .ended where agent.actions.close.isEnabled:
            [spec(.closePane, for: agent)]
        case .working, .ended:
            []
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
