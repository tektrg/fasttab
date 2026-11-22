import Testing
@testable import AgentBar

/// The composer rule (`.claude/compact-api-contract.md` "Composer input rule"), one row per case.
struct CompactDraftTests {
    private typealias D = CompactDraft

    @Test func bareCompactHasNoInstructionsAndNoFollowUp() {
        #expect(D.parse("/compact") == D(instructions: nil, followUp: nil))
    }

    @Test func textAfterCompactOnLineOneIsTheInstructions() {
        #expect(D.parse("/compact keep the plan") == D(instructions: "keep the plan", followUp: nil))
    }

    @Test func linesAfterTheFirstAreTheFollowUp() {
        #expect(D.parse("/compact\nnow run the tests") == D(instructions: nil, followUp: "now run the tests"))
        #expect(D.parse("/compact   \nnow run the tests") == D(instructions: nil, followUp: "now run the tests"))
    }

    @Test func instructionsAndFollowUpTogether() {
        #expect(D.parse("/compact keep the plan\nnow run the tests") == D(instructions: "keep the plan", followUp: "now run the tests"))
    }

    @Test func leadingAndTrailingWhitespaceIsTrimmed() {
        #expect(D.parse("   /compact   keep the plan   \n   go on   \n  ") == D(instructions: "keep the plan", followUp: "go on"))
        #expect(D.parse("  /compact  ") == D(instructions: nil, followUp: nil))
        #expect(D.parse("/compact\n   \n  ") == D(instructions: nil, followUp: nil))
    }

    @Test func aMultiLineFollowUpIsFlattenedToOneLine() {
        #expect(D.parse("/compact\nfirst line\n\n  second line  \nthird") == D(instructions: nil, followUp: "first line second line third"))
        #expect(D.parse("/compact x\r\na\r\nb") == D(instructions: "x", followUp: "a b"))
    }

    @Test func aLongerWordIsNotCompact() {
        #expect(D.parse("/compactx") == nil)
        #expect(D.parse("/compacting now") == nil)
        #expect(D.parse("/compactx\nhello") == nil)
    }

    @Test func compactOnALaterLineIsNotCompact() {
        #expect(D.parse("hello\n/compact") == nil)
        #expect(D.parse("\n/compact") == nil)
    }

    @Test func otherDraftsAreNotCompact() {
        #expect(D.parse("") == nil)
        #expect(D.parse("please compact") == nil)
        #expect(D.parse("/Compact") == nil)
        #expect(D.parse("/clear") == nil)
        #expect(D.parse("compact") == nil)
    }

    @Test func aPieceOverTheDashboardCapIsRefused() {
        let long = String(repeating: "a", count: MessageDraftValidator.maxLength + 3)
        #expect(D.parse("/compact\n" + long)?.refusal == MessageDraftValidator.tooLongHint(over: 3))
        #expect(D.parse("/compact " + long)?.refusal == MessageDraftValidator.tooLongHint(over: 3))
        #expect(D.parse("/compact ok\nfine")?.refusal == nil)
    }

    @Test func theHintSaysWhatShiftReturnDoes() {
        #expect(D.parse("/compact")?.hint.contains("⇧↩") == true)
        #expect(D.parse("/compact\nthen this")?.hint.contains("then sends") == true)
    }
}
