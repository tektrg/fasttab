import Foundation

extension QuestionIdentity {
    /// True when both texts are the same question once everything the pane's
    /// drawing adds is ignored: spaces, line breaks and box-border characters.
    /// The status feed reads the screen as drawn (a line wider than the pane
    /// is cut mid-word: "and a" / "lso"), the answer path reads it unwrapped,
    /// so the two copies of one question can differ in exactly those.
    func isSameQuestion(as other: QuestionIdentity) -> Bool {
        let title = Self.comparable(title), otherTitle = Self.comparable(other.title)
        let question = Self.comparable(question), otherQuestion = Self.comparable(other.question)
        guard !title.isEmpty, title == otherTitle else { return false }
        // A hook preview can carry only the start of the question.
        return question == otherQuestion || question.hasPrefix(otherQuestion) || otherQuestion.hasPrefix(question)
    }

    /// The identity to send: the pane's own reading when it is the same question
    /// as the one shown (the dashboard compares against its own reading, letter
    /// for letter); otherwise what was shown, so a genuinely different question
    /// is still refused by the dashboard rather than answered by mistake.
    func resolved(against paneReading: QuestionIdentity?) -> QuestionIdentity {
        guard let paneReading, isSameQuestion(as: paneReading) else { return self }
        return paneReading
    }

    /// The text with everything the pane's drawing adds removed: spaces, line breaks, box-border characters.
    static func comparable(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { scalar in
            !scalar.properties.isWhitespace && !(0x2500...0x257F).contains(scalar.value)
        }))
    }
}
