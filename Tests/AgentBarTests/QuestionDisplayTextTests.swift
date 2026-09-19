import Testing
@testable import AgentBar

/// The card shows the whole question and the whole of every option.
struct QuestionDisplayTextTests {
    private static let long = String(repeating: "Should the sample setting persist to disk per workspace or stay session only? ", count: 8)   // 600+ characters

    @Test func aLongQuestionIsNeverCutToALength() {
        #expect(Self.long.count > 400)
        let shown = QuestionDisplayText.clean(Self.long)
        #expect(shown == Self.long.trimmingCharacters(in: .whitespaces))
        #expect(!shown.contains("…"))
    }

    @Test func bordersAndStraySpacesGoButEveryWordStays() {
        #expect(QuestionDisplayText.clean("│ Should we persist  it? │ Yes or no?") == "Should we persist it? Yes or no?")
    }

    @Test func paragraphBreaksAreKeptAndBlankRunsShrinkToOne() {
        let raw = "First paragraph.\n\n\n  │ Second paragraph,\n  continued here.\n\n"
        #expect(QuestionDisplayText.clean(raw) == "First paragraph.\n\nSecond paragraph,\ncontinued here.")
    }

    @Test func aQuestionOfOnlyBordersFallsBackToTheRawTextOnTheCard() {
        let question = AnswerFixtures.question(question: "│ │")
        #expect(question.displayQuestion == "│ │")
    }

    @Test func aFullLongQuestionWithLongOptionsIsKeptByTheCardModel() {
        let question = AnswerFixtures.question(question: Self.long, labels: [String(repeating: "A very long option label ", count: 12)])
        #expect(question.displayQuestion.count > 400)
        #expect(question.options[0].label.count > 250)   // labels are never shortened either
    }
}

struct AnswerCardLayoutTests {
    @Test func shortMessagesNeedNoShowMore() {
        #expect(!AnswerCardLayout.messageNeedsToggle("Two short lines.\nRight here."))
    }

    @Test func aLongMessageOrManyLinesOffersShowMore() {
        #expect(AnswerCardLayout.messageNeedsToggle(String(repeating: "word ", count: 120)))
        #expect(AnswerCardLayout.messageNeedsToggle("1\n2\n3\n4\n5\n6"))
        #expect(!AnswerCardLayout.messageNeedsToggle("1\n2\n3\n4\n5"))
    }

    @Test func linesAreEstimatedPerParagraph() {
        #expect(AnswerCardLayout.estimatedLineCount(of: "", charactersPerLine: 10) == 1)
        #expect(AnswerCardLayout.estimatedLineCount(of: "12345678901\nabc", charactersPerLine: 10) == 3)
    }
}
