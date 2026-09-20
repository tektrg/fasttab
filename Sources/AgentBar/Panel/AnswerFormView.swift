import SwiftUI

/// Every question of a multi-question form in one column: header, question, its options (a radio dot for a
/// single-select, tick boxes for a multi-select) and a free-text "Other" row. Nothing here sends: the card's
/// Submit button does, once every question has an answer.
struct AnswerFormView: View {
    @ObservedObject var answer: AnswerCardModel
    let form: AnswerFormState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(form.form.questions.enumerated()), id: \.offset) { index, question in
                questionSection(index, question)
            }
        }
        .padding(.bottom, 8)
    }

    private func questionSection(_ index: Int, _ question: FormQuestion) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            heading(index, question)
            VStack(spacing: 2) {
                ForEach(Array(question.options.enumerated()), id: \.offset) { row, option in
                    optionRow(index, row: row, option: option, question: question)
                }
                otherRow(index, question: question)
            }
            .padding(.horizontal, 6)
            .allowsHitTesting(form.isEditable)
            .opacity(form.isEditable ? 1 : 0.6)
        }
    }

    private func heading(_ index: Int, _ question: FormQuestion) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("\(index + 1) of \(form.form.questions.count)\(question.header.isEmpty ? "" : " · " + question.header.uppercased())")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                outcomeChip(form.outcomes[index])
            }
            Text(QuestionDisplayText.clean(question.question))
                .font(.system(size: 15, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func outcomeChip(_ outcome: FormQuestionOutcome) -> some View {
        switch outcome {
        case .waiting: EmptyView()
        case .sending: chip("Sending…", .secondary)
        case .landed: chip("Sent", .green)
        case .skipped: chip("Skipped", WarningTextColor.color)
        case .refused: chip("Refused", .red)
        case .notSent: chip("Not sent", .red)
        case .recorded(_, let chose): chose == nil ? chip("Recorded", .green) : chip("Check it", WarningTextColor.color)
        }
    }

    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
    }

    private func optionRow(_ index: Int, row: Int, option: FormQuestion.Option, question: FormQuestion) -> some View {
        AnswerOptionRowView(
            option: .init(index: row + 1, label: option.label, description: option.description, isOther: false),
            isMultiSelect: question.isMultiSelect,
            isHighlighted: false,
            isChecked: form.isChecked(row: row, of: index),
            isTypingHere: false,
            choiceMarker: question.isMultiSelect ? .checkbox : .radio,
            otherText: .constant(""), onSubmitText: {}, onLeaveText: {}
        )
        .onTapGesture { answer.clickFormRow(row, of: index) }
    }

    private func otherRow(_ index: Int, question: FormQuestion) -> some View {
        let row = form.otherRow(of: index)
        return AnswerOptionRowView(
            option: .init(index: row + 1, label: "Other (type your own answer)", description: "", isOther: true),
            isMultiSelect: question.isMultiSelect,
            isHighlighted: false,
            isChecked: form.isChecked(row: row, of: index),
            isTypingHere: form.drafts[index].usesOther && form.isEditable,
            choiceMarker: .radio,
            typedTextNote: OtherAnswerText.note(for: form.drafts[index].otherText),
            otherText: Binding(get: { form.drafts[index].otherText }, set: { answer.setFormOtherText($0, of: index) }),
            onSubmitText: { answer.handle(.enter) },
            onLeaveText: { answer.releaseFormTextField() }
        )
        .onTapGesture { answer.clickFormRow(row, of: index) }
    }
}
