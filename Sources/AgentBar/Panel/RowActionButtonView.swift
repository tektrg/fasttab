import SwiftUI

/// One small button on an agent row (Answer, Open terminal, Done, Park, Unpark, Close pane).
/// A blocked agent's Answer / Open terminal is red: the one thing waiting on you.
/// Highlighted = the keyboard is on it; confirming = the second press is armed.
struct RowActionButtonView: View {
    let spec: RowButtonSpec
    let state: RowActionState?
    let isHighlighted: Bool
    let onPress: () -> Void

    var body: some View {
        Button(action: onPress) {
            Text(state == nil ? spec.label : RowActionText.title(of: spec.button, state: state))
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .foregroundStyle(foreground)
                .background(Capsule().fill(fill))
                .overlay(Capsule().strokeBorder(isHighlighted ? Color.accentColor : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .disabled(!isPressable)
        .opacity(spec.isEnabled ? 1 : 0.4)
        .help(spec.disabledReason ?? spec.hint ?? "")
        .accessibilityLabel(spec.button.title)
    }

    private var isConfirming: Bool {
        if case .confirming(let button, _)? = state { return button == spec.button }
        return false
    }

    /// A press is ignored while that button's request is in flight or done.
    private var isPressable: Bool {
        guard spec.isEnabled else { return false }
        switch state {
        case .busy(let button)?, .completed(let button)?: return button != spec.button
        case .confirming?, nil: return true
        }
    }

    private var fill: Color {
        if isConfirming { return Color.red.opacity(0.85) }
        if spec.button.isBlockedAction { return Color.red.opacity(isHighlighted ? 0.26 : 0.16) }
        return Color.primary.opacity(isHighlighted ? 0.18 : 0.10)
    }

    private var foreground: Color {
        if isConfirming { return .white }
        return spec.button.isBlockedAction ? Color.red : .primary
    }
}
