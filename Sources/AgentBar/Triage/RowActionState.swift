import Foundation

/// Where one row's Done / Close pane press has got to. A row with no state is idle.
enum RowActionState: Equatable, Sendable {
    /// The request is in flight; the button is disabled.
    case busy(RowButton)
    /// The dashboard said something is at stake; one more press confirms.
    case confirming(RowButton, reason: String)
    /// The dashboard did it. The row is waiting for the next status update to
    /// show the result (Done: the stopped pane; Close pane: gone).
    case completed(RowButton)

    var button: RowButton {
        switch self {
        case .busy(let button), .confirming(let button, _), .completed(let button): button
        }
    }
}

/// What pressing a button should do, given where the row's action stands.
enum RowActionPlan: Equatable {
    case ignore
    case park
    case unpark
    case openAnswer
    case openReview
    case openTerminal
    case openMessage
    /// Compact / Clear: straight to `MessageCardModel.sendDirect(to:text:)`, no card, no
    /// `MessageDraftValidator` (these two exact strings are pre-approved) and no confirm step.
    case sendQuickCommand(String)
    case send(SessionActionKind, confirmed: Bool)
    /// Report to… / Stop reporting: straight to `AgentTreeModel.indentSelected()`/`outdentSelected()`
    /// (`AgentPanelModel.press`) — no card, no confirm step here (the model's own cross-project
    /// confirm dialog and ambiguous-chief picker, unchanged, still apply where they did before).
    case reportToNearestChief
    case stopReporting
}

/// The Done / Close pane press flow: press -> (confirm) -> done. Pure; the
/// panel model does the sending and the state bookkeeping.
enum RowActionMachine {
    static func plan(pressing button: RowButton, current: RowActionState?) -> RowActionPlan {
        switch current {
        case .busy?, .completed?:
            return .ignore   // one request at a time, and nothing more to do once it worked
        case .confirming?, nil:
            break
        }
        switch button {
        case .answer: return .openAnswer
        case .review: return .openReview
        case .openTerminal: return .openTerminal
        case .message: return .openMessage
        case .park: return .park
        case .unpark: return .unpark
        case .compact: return .sendQuickCommand("/compact")
        case .clear: return .sendQuickCommand("/clear")
        case .reportTo: return .reportToNearestChief
        case .stopReporting: return .stopReporting
        // The ⋯ trigger itself is never "pressed" (`RowMoreMenuView` opens natively on click; a
        // keyboard Enter on the highlighted trigger cannot pop a SwiftUI `Menu` programmatically —
        // see its doc comment). Its items reach `plan` as their own `RowButton`s instead.
        case .moreActions: return .ignore
        case .done, .closePane:
            guard let kind = button.sessionAction else { return .ignore }
            if case .confirming(let confirming, _)? = current, confirming == button {
                return .send(kind, confirmed: true)
            }
            return .send(kind, confirmed: false)
        }
    }

    /// The row's state once the dashboard has answered a press of `button`.
    /// A failure clears the state (never a stuck row) and hands back its message.
    static func state(after outcome: SessionActionOutcome, pressing button: RowButton) -> (state: RowActionState?, failure: String?) {
        switch outcome {
        case .succeeded: (.completed(button), nil)
        case .needsConfirmation(let reason): (.confirming(button, reason: reason), nil)
        case .failed(let message): (nil, message)
        }
    }
}
