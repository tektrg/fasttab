import Foundation
import Testing
@testable import AgentBar

struct AnswerCardStateTests {
    typealias A = AnswerFixtures

    private func single(labels: [String] = ["Apple", "Banana"]) -> AnswerCardState {
        AnswerCardState(question: A.question(labels: labels))
    }

    private func multi() -> AnswerCardState {
        AnswerCardState(question: A.question(multi: true, labels: ["Red", "Green", "Blue"]))
    }

    // MARK: - Single select

    @Test func aDigitPicksThatOptionAtOnce() {
        var state = single()
        #expect(state.handle(.digit(2)) == .send(.select([2])))
    }

    @Test func aDigitWithNoSuchOptionDoesNothing() {
        var state = single()
        #expect(state.handle(.digit(9)) == .none)
    }

    @Test func aDigitOnTheFreeTextRowOpensTheTextFieldInsteadOfSending() {
        var state = single()   // options 1, 2, and 3 = free text
        #expect(state.handle(.digit(3)) == .none)
        #expect(state.phase == .typingOther)
    }

    @Test func arrowsMoveTheHighlightAndStopAtTheEnds() {
        var state = single()
        #expect(state.highlightedPosition == 0)
        _ = state.handle(.up)
        #expect(state.highlightedPosition == 0)
        _ = state.handle(.down)
        _ = state.handle(.down)
        _ = state.handle(.down)
        #expect(state.highlightedPosition == 2)
    }

    @Test func enterSendsTheHighlightedOption() {
        var state = single()
        _ = state.handle(.down)
        #expect(state.handle(.enter) == .send(.select([2])))
    }

    @Test func enterOnTheFreeTextRowOpensTheTextField() {
        var state = single()
        _ = state.handle(.down)
        _ = state.handle(.down)
        #expect(state.handle(.enter) == .none)
        #expect(state.phase == .typingOther)
    }

    @Test func spaceDoesNothingInASingleSelect() {
        var state = single()
        #expect(state.handle(.space) == .none)
        #expect(state.readyChoice == .select([1]))
    }

    @Test func escapeLeavesTheCard() {
        var state = single()
        #expect(state.handle(.escape) == .close)
    }

    // MARK: - Free text

    @Test func typedTextIsSentTrimmedOnEnter() {
        var state = single()
        _ = state.handle(.digit(3))
        state.otherText = "  something else \n"
        #expect(state.handle(.enter) == .send(.text("something else")))
    }

    @Test func aMultiLineAnswerIsSentOnOneLineAndTheCardSaysSo() {
        var state = single()
        _ = state.handle(.digit(3))
        state.otherText = "first\nsecond"
        #expect(state.otherTextNote != nil)
        #expect(state.handle(.enter) == .send(.text("first second")))
    }

    @Test func noNoteWhileNotTypingOrWhenTheTextGoesAsTyped() {
        var state = single()
        #expect(state.otherTextNote == nil)
        _ = state.handle(.digit(3))
        state.otherText = "plain"
        #expect(state.otherTextNote == nil)
    }

    @Test func enterOnEmptyTextSendsNothing() {
        var state = single()
        _ = state.handle(.digit(3))
        state.otherText = "   "
        #expect(state.handle(.enter) == .none)
    }

    @Test func escapeInTheTextFieldGoesBackToTheOptionsNotOutOfTheCard() {
        var state = single()
        _ = state.handle(.digit(3))
        #expect(state.handle(.escape) == .none)
        #expect(state.phase == .choosing)
        #expect(state.handle(.escape) == .close)
    }

    @Test func digitsAndArrowsBelongToTheTextFieldWhileTyping() {
        var state = single()
        _ = state.handle(.digit(3))
        #expect(state.handle(.digit(1)) == .none)
        #expect(state.handle(.up) == .none)
        #expect(state.phase == .typingOther)
        #expect(state.highlightedPosition == 2)
    }

    // MARK: - Multi select

    @Test func digitsAndSpaceTickAndUntickWithoutSending() {
        var state = multi()   // 1 Red, 2 Green, 3 Blue, 4 free text
        #expect(state.handle(.digit(2)) == .none)
        #expect(state.handle(.digit(3)) == .none)
        #expect(state.checkedIndices == [2, 3])
        #expect(state.handle(.digit(2)) == .none)
        #expect(state.checkedIndices == [3])
        _ = state.handle(.space)   // the highlight followed the last digit (2)
        #expect(state.checkedIndices == [2, 3])
    }

    @Test func enterSubmitsTheTickedOptionsInOrder() {
        var state = multi()
        _ = state.handle(.digit(3))
        _ = state.handle(.digit(1))
        #expect(state.handle(.enter) == .send(.select([1, 3])))
    }

    @Test func enterWithNothingTickedAsksForATickInsteadOfSendingAGuess() {
        var state = multi()
        #expect(state.handle(.enter) == .none)
        #expect(state.errorText == AnswerCardState.pickAtLeastOneMessage)
        _ = state.handle(.digit(1))
        #expect(state.errorText == nil)
    }

    @Test func spaceOrEnterOnTheFreeTextRowOpensTheTextFieldInAMultiSelect() {
        var state = multi()
        for _ in 0..<3 { _ = state.handle(.down) }
        #expect(state.handle(.space) == .none)
        #expect(state.phase == .typingOther)
        state.otherText = "purple"
        #expect(state.handle(.enter) == .send(.text("purple")))
    }

    @Test func aTickedOptionIsNotSentAlongsideTheFreeText() {
        var state = multi()
        _ = state.handle(.digit(1))
        _ = state.handle(.digit(4))
        state.otherText = "purple"
        #expect(state.readyChoice == .text("purple"))
    }

    // MARK: - Leaving the text field

    @Test func upFromTheTextFieldGoesBackToTheOptionsOneUpWithTheTextKept() {
        var state = single()
        _ = state.handle(.digit(3))
        state.otherText = "half typed"
        #expect(state.handle(.leaveTypingUp) == .none)
        #expect(state.phase == .choosing)
        #expect(state.highlightedPosition == 1)
        #expect(state.otherText == "half typed")
        #expect(state.handle(.up) == .none)   // the list's own keys work again
        #expect(state.highlightedPosition == 0)
    }

    @Test func downFromTheTextFieldOnTheLastOptionStaysOnItButLeavesTheField() {
        var state = single()
        _ = state.handle(.digit(3))
        #expect(state.handle(.leaveTypingDown) == .none)
        #expect(state.phase == .choosing)
        #expect(state.highlightedPosition == 2)
    }

    @Test func escapeKeepsTheTextAndEnteringOtherAgainRestoresIt() {
        var state = single()
        _ = state.handle(.digit(3))
        state.otherText = "kept"
        _ = state.handle(.escape)
        #expect(state.otherText == "kept")
        _ = state.handle(.enter)   // still on the Other row
        #expect(state.phase == .typingOther)
        #expect(state.readyChoice == .text("kept"))
    }

    @Test func digitsWorkFromTheListAfterLeavingTheField() {
        var state = single()
        _ = state.handle(.digit(3))
        _ = state.handle(.escape)
        #expect(state.handle(.digit(2)) == .send(.select([2])))
    }

    @Test func leavingTheFieldInAMultiSelectKeepsTicksAndTextAndSubmitButtonSendsTheTicks() {
        var state = multi()
        _ = state.handle(.digit(1))
        _ = state.handle(.digit(4))   // Other
        state.otherText = "purple"
        _ = state.handle(.leaveTypingUp)
        #expect(state.phase == .choosing)
        #expect(state.checkedIndices == [1])
        #expect(state.otherText == "purple")
        _ = state.handle(.down)   // back on Other in the list
        #expect(state.pressSend() == .send(.select([1])))   // the button sends the ticks, it never opens the field
        #expect(state.handle(.enter) == .none)   // Enter on Other opens the field again
        #expect(state.phase == .typingOther)
    }

    @Test func clickingAnotherOptionFromTheTextFieldLeavesItKeepingTheText() {
        var state = single()
        _ = state.handle(.digit(3))
        state.otherText = "kept"
        state.clickOption(at: 0)
        #expect(state.phase == .choosing)
        #expect(state.highlightedPosition == 0)
        #expect(state.otherText == "kept")
        state.clickOption(at: 2)   // Other again
        #expect(state.phase == .typingOther)
        #expect(state.otherText == "kept")
    }

    @Test func clickingATickInAMultiSelectFromTheTextFieldTicksIt() {
        var state = multi()
        _ = state.handle(.digit(4))
        state.clickOption(at: 1)
        #expect(state.phase == .choosing)
        #expect(state.checkedIndices == [2])
    }

    // MARK: - Drafts

    @Test func aDraftBringsBackWhatWasPickedAndTypedForTheSameQuestionOnly() {
        var state = multi()
        _ = state.handle(.digit(2))
        _ = state.handle(.digit(4))
        state.otherText = "mine"
        let draft = state.draft
        var fresh = multi()
        fresh.restore(draft)
        #expect(fresh.checkedIndices == [2])
        #expect(fresh.otherText == "mine")
        var other = AnswerCardState(question: A.question(title: "Colour", question: "Which colour?", multi: true, labels: ["Red", "Green", "Blue"]))
        other.restore(draft)
        #expect(other.checkedIndices.isEmpty)
        #expect(other.otherText.isEmpty)
    }

    @Test func replacingTheQuestionStartsOverButKeepsTheMessage() {
        var state = AnswerCardState(question: A.question(multi: true, labels: ["Red", "Green", "Blue"]), errorText: "hint")
        _ = state.handle(.digit(1))
        let replaced = state.replacing(question: A.question(title: "Colour", question: "Which colour?"))
        #expect(replaced.question.title == "Colour")
        #expect(replaced.checkedIndices.isEmpty)
        #expect(replaced.highlightedPosition == 0)
        #expect(replaced.errorText == nil || replaced.errorText == "hint")
    }

    // MARK: - Mouse

    @Test func clickingHighlightsInASingleSelectAndNeverSends() {
        var state = single()
        state.clickOption(at: 1)
        #expect(state.highlightedPosition == 1)
        #expect(state.pressSend() == .send(.select([2])))
    }

    @Test func clickingTicksInAMultiSelectAndOpensTheFreeTextRow() {
        var state = multi()
        state.clickOption(at: 0)
        #expect(state.checkedIndices == [1])
        state.clickOption(at: 3)
        #expect(state.phase == .typingOther)
    }

    @Test func hintsFollowThePhase() {
        var state = single()
        #expect(state.hintMode == .singleSelect)
        #expect(multi().hintMode == .multiSelect)
        _ = state.handle(.digit(3))
        #expect(state.hintMode == .typing)
    }
}
