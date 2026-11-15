import Testing
@testable import AgentBar

/// Focus mode's keyboard over a multi-question form: 3 questions × (2 options + Other).
struct FocusFormCursorTests {
    private func form(multi: Set<Int> = []) -> AnswerFormState { AnswerFormState(form: FormFixtures.form(multiSelect: multi)) }

    private func apply(_ effect: FocusFormCursor.Effect, to form: inout AnswerFormState) {
        if case .click(let row, let question) = effect { form.click(row: row, of: question) }
    }

    @Test func startsAtTopAndResetsForAnotherForm() {
        let state = form()
        var cursor = FocusFormCursor.current(nil, for: state)
        #expect(cursor.question == 0 && cursor.row == 0)
        cursor.question = 2
        #expect(FocusFormCursor.current(cursor, for: state).question == 2)
        cursor.formID = "other"
        #expect(FocusFormCursor.current(cursor, for: state).question == 0)
    }

    @Test func arrowsCrossQuestionsThroughOtherWithoutWrapping() {
        let state = form()
        var cursor = FocusFormCursor.current(nil, for: state)
        cursor.move(by: -1, in: state)
        #expect(cursor.question == 0 && cursor.row == 0)
        cursor.move(by: 2, in: state)
        #expect(cursor.question == 0 && cursor.row == 2) // Other
        cursor.move(by: 1, in: state)
        #expect(cursor.question == 1 && cursor.row == 0)
        cursor.move(by: 100, in: state)
        #expect(cursor.question == 2 && cursor.row == 2)
    }

    @Test func digitChoosesWithinTheHighlightedQuestionAndAdvances() {
        var state = form()
        var cursor = FocusFormCursor.current(nil, for: state)
        let effect = cursor.pick(2, in: state)
        #expect(effect == .click(row: 1, question: 0))
        apply(effect, to: &state)
        cursor.advanceAfterChoice(in: state)
        #expect(state.isChecked(row: 1, of: 0))
        #expect(cursor.question == 1 && cursor.row == 0)
        #expect(cursor.pick(9, in: state) == .none)
    }

    @Test func enterChoosesThenSubmitsOnceComplete() {
        var state = form()
        var cursor = FocusFormCursor.current(nil, for: state)
        for _ in 0..<3 {
            let effect = cursor.enter(in: state)
            #expect(effect != .submit)
            apply(effect, to: &state)
            cursor.advanceAfterChoice(in: state)
        }
        #expect(state.canSubmit)
        #expect(cursor.enter(in: state) == .submit)
    }

    @Test func spaceTogglesAMultiSelectTickAndStays() {
        var state = form(multi: [0])
        var cursor = FocusFormCursor.current(nil, for: state)
        apply(cursor.space(in: state), to: &state)
        #expect(state.isChecked(row: 0, of: 0))
        cursor.advanceAfterChoice(in: state)
        #expect(cursor.question == 0)
        apply(cursor.space(in: state), to: &state)
        #expect(!state.isChecked(row: 0, of: 0))
    }

    @Test func otherRowIsChosenButTheCursorStaysForTyping() {
        var state = form()
        var cursor = FocusFormCursor.current(nil, for: state)
        let effect = cursor.pick(3, in: state)
        #expect(effect == .click(row: 2, question: 0))
        apply(effect, to: &state)
        cursor.advanceAfterChoice(in: state)
        #expect(state.drafts[0].usesOther)
        #expect(cursor.question == 0 && cursor.row == 2)
    }
}
