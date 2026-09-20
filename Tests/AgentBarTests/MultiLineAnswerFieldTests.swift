import AppKit
import Testing
@testable import AgentBar

/// Return sends the free-text answer; Shift+Return adds a line.
@MainActor
struct MultiLineAnswerFieldTests {
    private func press(_ code: UInt16, flags: NSEvent.ModifierFlags = [], on view: AnswerTextView) {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: code
        )!
        view.keyDown(with: event)
    }

    @Test func returnSendsAndAddsNoLine() {
        let view = AnswerTextView()
        var sent = 0
        view.onSubmit = { sent += 1 }
        view.string = "abc"
        press(36, on: view)
        press(76, on: view)   // keypad Enter
        #expect(sent == 2)
        #expect(view.string == "abc")
    }

    @Test func aHeldReturnSendsNothingMoreAndAddsNoLine() {
        let view = AnswerTextView()
        var sent = 0
        view.onSubmit = { sent += 1 }
        view.string = "abc"
        let repeated = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: true, keyCode: 36
        )!
        view.keyDown(with: repeated)
        #expect(sent == 0 && view.string == "abc")
    }

    @Test func shiftReturnAddsALineAndSendsNothing() {
        let view = AnswerTextView()
        var sent = 0
        view.onSubmit = { sent += 1 }
        view.string = "abc"
        view.setSelectedRange(NSRange(location: 3, length: 0))
        press(36, flags: .shift, on: view)
        #expect(view.string == "abc\n")
        #expect(sent == 0)
    }

    @Test func shiftReturnInsertsAtTheCaretNotTheEnd() {
        let view = AnswerTextView()
        view.string = "abcd"
        view.setSelectedRange(NSRange(location: 2, length: 0))
        press(36, flags: .shift, on: view)
        #expect(view.string == "ab\ncd")
    }

    @Test func optionReturnAlsoAddsALine() {
        let view = AnswerTextView()
        var sent = 0
        view.onSubmit = { sent += 1 }
        press(36, flags: .option, on: view)
        #expect(view.string == "\n")
        #expect(sent == 0)
    }

    @Test func escapeGoesBackAndTypesNothing() {
        let view = AnswerTextView()
        var left = 0
        view.onLeave = { left += 1 }
        view.string = "x"
        press(53, on: view)
        #expect(left == 1)
        #expect(view.string == "x")
    }

    private func arrow(_ code: UInt16, on view: AnswerTextView) {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code
        )!
        view.keyDown(with: event)
    }

    @Test func upOnTheFirstLineLeavesTheFieldAndOnALaterLineMovesTheCaret() {
        let view = AnswerTextView()
        var left = 0
        view.onLeaveUp = { left += 1 }
        view.string = "first\nsecond"
        view.setSelectedRange(NSRange(location: 2, length: 0))
        #expect(view.caretIsOnFirstLine)
        arrow(AnswerTextView.upArrowKeyCode, on: view)
        #expect(left == 1)
        view.setSelectedRange(NSRange(location: 9, length: 0))
        #expect(!view.caretIsOnFirstLine)
        arrow(AnswerTextView.upArrowKeyCode, on: view)
        #expect(left == 1)   // the caret moved up instead
    }

    @Test func downOnTheLastLineLeavesTheFieldAndOnAnEarlierLineMovesTheCaret() {
        let view = AnswerTextView()
        var left = 0
        view.onLeaveDown = { left += 1 }
        view.string = "first\nsecond"
        view.setSelectedRange(NSRange(location: 9, length: 0))
        #expect(view.caretIsOnLastLine)
        arrow(AnswerTextView.downArrowKeyCode, on: view)
        #expect(left == 1)
        view.setSelectedRange(NSRange(location: 1, length: 0))
        #expect(!view.caretIsOnLastLine)
        arrow(AnswerTextView.downArrowKeyCode, on: view)
        #expect(left == 1)
    }

    @Test func aFinalLineBreakCountsAsAnEmptyLastLine() {
        let view = AnswerTextView()
        view.string = "abc\n"
        view.setSelectedRange(NSRange(location: 4, length: 0))
        #expect(view.caretIsOnLastLine)
        #expect(!view.caretIsOnFirstLine)
        view.setSelectedRange(NSRange(location: 1, length: 0))
        #expect(view.caretIsOnFirstLine)
        #expect(!view.caretIsOnLastLine)
    }

    @Test func anEmptyFieldIsBothFirstAndLast() {
        let view = AnswerTextView()
        #expect(view.caretIsOnFirstLine && view.caretIsOnLastLine)
    }
}
