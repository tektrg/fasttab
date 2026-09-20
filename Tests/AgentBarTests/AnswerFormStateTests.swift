import Foundation
import Testing
@testable import AgentBar

/// Matching the terminal's question to the form, and the drafts / Submit rule of the multi-question card.
struct QuestionFormMatchingTests {
    private let form = FormFixtures.form()

    @Test func aQuestionIsFoundByItsTextWhateverTheWrapping() {
        #expect(form.indexOfQuestion(matching: "What should \"Done\" do to an agent?") == 0)
        #expect(form.indexOfQuestion(matching: "After you press Done or Park, the agent later starts working again and  finishes. What should happen?") == 1)
        // the status feed cuts a line mid-word: "a lso"
        #expect(form.indexOfQuestion(matching: "Should the orange menu-bar count and macOS notif ication be built in this round too?") == 2)
        #expect(form.indexOfQuestion(matching: "│ Should the orange menu-bar count and macOS notification\n│ be built in this round too?") == 2)
    }

    @Test func aPreviewCutShortMatchesOnlyWhenItIsUnambiguous() {
        #expect(form.indexOfQuestion(matching: "What should \"Done\"") == 0)
        #expect(form.indexOfQuestion(matching: "Should the orange") == 2)
        let twins = PendingQuestionForm(toolUseId: "t", questions: [
            FormQuestion(header: "A", question: "Pick one for the app?", isMultiSelect: false, options: [.init(label: "x", description: "")]),
            FormQuestion(header: "B", question: "Pick one for the site?", isMultiSelect: false, options: [.init(label: "x", description: "")])
        ])
        #expect(twins.indexOfQuestion(matching: "Pick one") == nil)
        #expect(twins.indexOfQuestion(matching: "Pick one for the site?") == 1)
    }

    @Test func aQuestionOfAnotherFormOrNoTextMatchesNothing() {
        #expect(form.indexOfQuestion(matching: "Which fruit?") == nil)
        #expect(form.indexOfQuestion(matching: "  ") == nil)
    }
}

struct AnswerFormStateTests {
    private func state(multi: Set<Int> = []) -> AnswerFormState { AnswerFormState(form: FormFixtures.form(multiSelect: multi)) }

    @Test func submitNeedsEveryQuestionAnswered() {
        var form = state()
        #expect(!form.canSubmit && form.answeredCount == 0 && form.choices == nil)
        form.click(row: 0, of: 0)
        form.click(row: 1, of: 1)
        #expect(!form.canSubmit && form.answeredCount == 2)
        form.click(row: 0, of: 2)
        #expect(form.canSubmit && form.answeredCount == 3)
        #expect(form.choices == [.options([0]), .options([1]), .options([0])])
    }

    @Test func aSingleSelectIsARadioChoosingAgainMovesIt() {
        var form = state()
        form.click(row: 0, of: 0)
        form.click(row: 1, of: 0)
        #expect(form.choice(for: 0) == .options([1]))
        #expect(form.isChecked(row: 1, of: 0) && !form.isChecked(row: 0, of: 0))
    }

    @Test func aMultiSelectTogglesAndNeedsAtLeastOneTick() {
        var form = state(multi: [1])
        form.click(row: 0, of: 1)
        form.click(row: 1, of: 1)
        #expect(form.choice(for: 1) == .options([0, 1]))
        form.click(row: 0, of: 1)
        form.click(row: 1, of: 1)
        #expect(form.choice(for: 1) == nil)
    }

    @Test func otherCountsOnlyWithText_andReplacesTheTicks() {
        var form = state(multi: [0])
        form.click(row: 0, of: 0)
        form.click(row: form.otherRow(of: 0), of: 0)
        #expect(form.choice(for: 0) == nil)   // Other picked, nothing typed yet
        form.setOtherText("  my own\nanswer  ", of: 0)
        #expect(form.choice(for: 0) == .other("my own answer"))
        #expect(!form.isChecked(row: 0, of: 0))
        form.click(row: 1, of: 0)   // an option again drops Other but keeps the typed text for later
        #expect(form.choice(for: 0) == .options([1]))
        #expect(form.drafts[0].otherText == "  my own\nanswer  ")
    }

    @Test func aClickOutsideTheRowsIsIgnored() {
        var form = state()
        form.click(row: 9, of: 0)
        form.click(row: -1, of: 0)
        form.click(row: 0, of: 7)
        #expect(form.answeredCount == 0)
    }

    @Test func nothingChangesOnceSendingStarted() {
        var form = state()
        for question in 0..<3 { form.click(row: 0, of: question) }
        form.beginSending()
        #expect(form.sendState == .sending(question: 0) && !form.canSubmit)
        form.click(row: 1, of: 0)
        form.setOtherText("x", of: 0)
        #expect(form.choice(for: 0) == .options([0]))
        form.beginSending()   // a second press is nothing
        #expect(form.sendState == .sending(question: 0))
    }

    @Test func beginSendingRefusesAnIncompleteForm() {
        var form = state()
        form.click(row: 0, of: 0)
        form.beginSending()
        #expect(form.sendState == .editing)
    }

    @Test func progressAndStopAreKept() {
        var form = state()
        form.record(.landed, for: 0)
        form.record(.sending, for: 1)
        #expect(form.sendState == .sending(question: 1) && form.outcomes[0] == .landed)
        let result = FormBatchResult(outcomes: [.landed, .refused("no"), .notSent("x")], stopReason: "Stopped", finalNext: nil, seenIdentities: [])
        form.stop(result: result, report: "the report")
        #expect(form.sendState == .stopped && form.report == "the report" && form.outcomes == result.outcomes)
    }
}
