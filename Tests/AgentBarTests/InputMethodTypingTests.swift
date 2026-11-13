import AppKit
import SwiftUI
import Testing
@testable import AgentBar

/// Vietnamese Telex tools (OpenKey) fix a word by typing Backspace + the accented letter, faster than
/// SwiftUI hands the binding back; other input methods compose with marked text. Either way the box
/// must keep what was typed when a render arrives with the binding's late (older) value.
@MainActor
struct InputMethodTypingTests {
    /// A real box wired the way `MultiLineAnswerField` wires it.
    private func makeBox() -> (AnswerTextView, MultiLineAnswerField.Coordinator) {
        let field = MultiLineAnswerField(text: .constant(""), onSubmit: {}, onLeave: {})
        let coordinator = MultiLineAnswerField.Coordinator(field)
        let box = AnswerTextView()
        box.delegate = coordinator
        return (box, coordinator)
    }

    private func type(_ text: String, into box: AnswerTextView) {
        box.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    @Test func telexBackspaceAndReplacementSurviveALateRender() {
        let (box, coordinator) = makeBox()
        // "dduowc" -> "được": OpenKey types d, d (Backspace + "đ"), u, o, then Backspace x2 + "ươ", then w/c fix-ups.
        type("d", into: box); box.deleteBackward(nil); type("đ", into: box); type("u", into: box); type("o", into: box)
        box.deleteBackward(nil); box.deleteBackward(nil)
        type("ươ", into: box)
        box.deleteBackward(nil); box.deleteBackward(nil)
        type("ược", into: box)
        // SwiftUI renders with a value the binding held a few keys ago.
        MultiLineAnswerField.apply(modelText: "đuo", to: box, coordinator: coordinator)
        MultiLineAnswerField.apply(modelText: "đươ", to: box, coordinator: coordinator)
        #expect(box.string == "được")
        // The binding catches up: nothing changes.
        MultiLineAnswerField.apply(modelText: "được", to: box, coordinator: coordinator)
        #expect(box.string == "được")
    }

    @Test func replacementRangeInsertSurvivesALateRender() {
        let (box, coordinator) = makeBox()
        type("đuoc", into: box)
        box.insertText("ược", replacementRange: NSRange(location: 1, length: 3))
        MultiLineAnswerField.apply(modelText: "đuoc", to: box, coordinator: coordinator)
        #expect(box.string == "được")
    }

    @Test func markedTextIsNotWipedByARender() {
        let (box, coordinator) = makeBox()
        type("đ", into: box)
        box.setMarkedText("ư", selectedRange: NSRange(location: 1, length: 0),
                          replacementRange: NSRange(location: NSNotFound, length: 0))
        MultiLineAnswerField.apply(modelText: "", to: box, coordinator: coordinator)
        #expect(box.hasMarkedText())
        box.insertText("ược", replacementRange: NSRange(location: NSNotFound, length: 0))
        MultiLineAnswerField.apply(modelText: "đ", to: box, coordinator: coordinator)
        #expect(box.string == "được")
    }

    @Test func aRealOutsideChangeStillLands() {
        let (box, coordinator) = makeBox()
        type("hello", into: box)
        MultiLineAnswerField.apply(modelText: "hello", to: box, coordinator: coordinator)
        MultiLineAnswerField.apply(modelText: "", to: box, coordinator: coordinator)   // cleared after Send
        #expect(box.string == "")
        MultiLineAnswerField.apply(modelText: "restored draft", to: box, coordinator: coordinator)
        #expect(box.string == "restored draft")
    }

    @Test func plainTypingStillWorks() {
        let (box, coordinator) = makeBox()
        for letter in "abc" {
            type(String(letter), into: box)
            MultiLineAnswerField.apply(modelText: box.string, to: box, coordinator: coordinator)
        }
        #expect(box.string == "abc")
        #expect(coordinator.reported.isEmpty)
    }

    /// Live trace 2026-11-13 (plain US keyboard): every render carried the text from ONE KEY EARLIER,
    /// and the box was overwritten each time ("s" -> "", "d" -> "s"), so letters vanished.
    @Test func aBindingOneKeyBehindLosesNoLetters() {
        let (box, coordinator) = makeBox()
        var previous = ""
        for letter in "sdf asf" {
            type(String(letter), into: box)
            MultiLineAnswerField.apply(modelText: previous, to: box, coordinator: coordinator)
            previous = box.string
        }
        #expect(box.string == "sdf asf")
        MultiLineAnswerField.apply(modelText: "sdf asf", to: box, coordinator: coordinator)
        MultiLineAnswerField.apply(modelText: "", to: box, coordinator: coordinator)   // cleared after Send
        #expect(box.string == "")
    }
}
