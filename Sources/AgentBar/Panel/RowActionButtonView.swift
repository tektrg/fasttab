import SwiftUI
import IndieCommandBar

/// One small button on an agent row (Answer, Open terminal, Done, Park, Unpark, Close pane), drawn by
/// the shared `RowActionCapsuleButton` (IndieCommandBar) with its confirm and busy states.
/// A blocked agent's Answer / Open terminal is red: the one thing waiting on you.
/// Highlighted = the keyboard is on it; confirming = the second press is armed.
struct RowActionButtonView: View {
    let spec: RowButtonSpec
    /// The idle label instead of the button's own (the action row's Close / Go to agent).
    var titleOverride: String? = nil
    let state: RowActionState?
    let isHighlighted: Bool
    var fontSize: CGFloat = 11
    let onPress: () -> Void

    var body: some View {
        RowActionCapsuleButton(
            titles: titleOverride.map { RowActionButtonTitles(idle: $0, confirming: $0, busy: $0, done: $0) } ?? Self.titles(for: spec),
            phase: Self.phase(of: spec.button, state: state),
            isAlert: spec.isBlockedAction,
            isHighlighted: isHighlighted,
            isEnabled: spec.isEnabled,
            help: spec.disabledReason ?? spec.hint ?? "",
            font: .avenir(size: fontSize, weight: .medium),
            action: onPress
        )
    }

    /// The shared phase for `button`: only the button the row's action is about leaves idle.
    nonisolated static func phase(of button: RowButton, state: RowActionState?) -> RowActionButtonPhase {
        guard let state, state.button == button else { return .idle }
        switch state {
        case .busy: return .busy
        case .confirming: return .confirming
        case .completed: return .done
        }
    }

    /// The words per phase: the button's label idle, else Agent Bar's own ("Confirm", "Stopping…", "Closed").
    nonisolated static func titles(for spec: RowButtonSpec) -> RowActionButtonTitles {
        let button = spec.button
        return RowActionButtonTitles(
            idle: spec.label,
            confirming: RowActionText.title(of: button, state: .confirming(button, reason: "")),
            busy: RowActionText.title(of: button, state: .busy(button)),
            done: RowActionText.title(of: button, state: .completed(button))
        )
    }
}
