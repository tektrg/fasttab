import Foundation

/// Focus mode's keyboard highlight inside a multi-question form (pure, unit-tested). The panel's form
/// card is mouse-only; Focus adds ↑/↓ across every question's rows (Other included), 1–9 within the
/// highlighted question, Space/↩ to choose. Every choice goes through `AnswerCardModel.clickFormRow`,
/// Submit through the card's own `handle(.enter)`: nothing is sent from here.
struct FocusFormCursor: Equatable {
    /// The form this cursor belongs to (`PendingQuestionForm.toolUseId`); another form starts at the top.
    var formID: String
    var question = 0
    var row = 0

    /// What a key asks the form card to do.
    enum Effect: Equatable {
        case none
        /// Click `row` of `question` (`AnswerCardModel.clickFormRow`).
        case click(row: Int, question: Int)
        /// Every question answered and ↩ pressed on an already-chosen row: Submit.
        case submit
    }

    /// The cursor for `form`: kept when it is the same form, reset to the top otherwise.
    static func current(_ cursor: FocusFormCursor?, for form: AnswerFormState) -> FocusFormCursor {
        if let cursor, cursor.formID == form.form.toolUseId { return cursor.clamped(to: form) }
        return FocusFormCursor(formID: form.form.toolUseId)
    }

    private func clamped(to form: AnswerFormState) -> FocusFormCursor {
        var copy = self
        copy.question = min(max(0, question), form.form.questions.count - 1)
        copy.row = min(max(0, row), form.otherRow(of: copy.question))
        return copy
    }

    /// ↑/↓: one row at a time across question boundaries; no wrap at either end.
    mutating func move(by step: Int, in form: AnswerFormState) {
        var flat: [(Int, Int)] = []
        for q in form.form.questions.indices {
            for r in 0...form.otherRow(of: q) { flat.append((q, r)) }
        }
        guard let here = flat.firstIndex(where: { $0 == (question, row) }) else { return }
        let next = min(max(0, here + step), flat.count - 1)
        (question, row) = flat[next]
    }

    /// 1–9: that row of the highlighted question (the Other row counts), chosen at once.
    mutating func pick(_ number: Int, in form: AnswerFormState) -> Effect {
        let target = number - 1
        guard form.isEditable, (0...form.otherRow(of: question)).contains(target) else { return .none }
        row = target
        return chooseHighlighted(in: form)
    }

    /// Space: choose (or untick) the highlighted row.
    func space(in form: AnswerFormState) -> Effect {
        form.isEditable ? .click(row: row, question: question) : .none
    }

    /// ↩: Submit once everything is answered and the highlighted row is already chosen; otherwise choose it.
    mutating func enter(in form: AnswerFormState) -> Effect {
        guard form.isEditable else { return .none }
        if form.canSubmit, form.isChecked(row: row, of: question) { return .submit }
        return chooseHighlighted(in: form)
    }

    /// After choosing a single-select option, the highlight moves to the next question's first row
    /// (a multi-select stays put for more ticks; Other stays put for typing).
    mutating func advanceAfterChoice(in form: AnswerFormState) {
        let q = form.form.questions[question]
        guard !q.isMultiSelect, row != form.otherRow(of: question), question + 1 < form.form.questions.count else { return }
        question += 1
        row = 0
    }

    private mutating func chooseHighlighted(in form: AnswerFormState) -> Effect {
        // A single-select option already chosen is not clicked again (a click would be a no-op anyway).
        let q = form.form.questions[question]
        if !q.isMultiSelect, row != form.otherRow(of: question), form.isChecked(row: row, of: question) {
            return .none
        }
        return .click(row: row, question: question)
    }
}
