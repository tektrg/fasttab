import SwiftUI

/// One option of the question: its number (the key that picks it), label and
/// description; a tick box in a multi-select; the text field on the free-text
/// row while the user types.
struct AnswerOptionRowView: View {
    let option: AnswerableQuestion.Option
    let isMultiSelect: Bool
    let isHighlighted: Bool
    let isChecked: Bool
    let isTypingHere: Bool
    /// What sending will change about the typed text (line breaks), when it will.
    var typedTextNote: String?
    @Binding var otherText: String
    let onSubmitText: () -> Void
    let onLeaveText: () -> Void
    /// ↑ / ↓ in the text field with the caret on its first / last line.
    var onLeaveTextUp: () -> Void = {}
    var onLeaveTextDown: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(option.index)")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.10)))
            if isMultiSelect && !option.isOther {
                Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isChecked ? Color.accentColor : .secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                if isTypingHere {
                    textField
                } else {
                    Text(option.label)
                        .font(.system(size: 13, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !option.description.isEmpty && !isTypingHere {
                    Text(option.description)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if isTypingHere, let typedTextNote {
                    Text(typedTextNote)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                if isTypingHere && isMultiSelect {
                    Text("Sends only this text; ticked options are not sent with it.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(isHighlighted ? Color.accentColor.opacity(0.22) : .clear))
        .contentShape(Rectangle())
    }

    /// Return sends; Shift+Return adds a line.
    private var textField: some View {
        MultiLineAnswerField(
            text: $otherText, onSubmit: onSubmitText, onLeave: onLeaveText,
            onLeaveUp: onLeaveTextUp, onLeaveDown: onLeaveTextDown
        )
            .frame(height: Self.textHeight)
            .overlay(alignment: .topLeading) {
                if otherText.isEmpty {
                    Text("Type your answer (⇧↩ for a new line)")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                        .allowsHitTesting(false)
                }
            }
    }

    /// About three lines; longer text scrolls inside.
    static let textHeight: CGFloat = 52
}
