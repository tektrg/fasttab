import Testing
@testable import AgentBar

/// What of a typed "Other" answer reaches the agent (the dashboard flattens line breaks).
struct OtherAnswerTextTests {
    @Test func lineBreaksAndRunsOfSpacesBecomeSingleSpaces() {
        #expect(OtherAnswerText.sendable("  first line\nsecond   line\r\n\tthird \n") == "first line second line third")
    }

    @Test func nothingButWhitespaceSendsNothing() {
        #expect(OtherAnswerText.sendable(" \n\t ") == nil)
        #expect(OtherAnswerText.sendable("") == nil)
    }

    @Test func textOverTheDashboardsCapIsCutToIt() throws {
        let long = String(repeating: "a", count: 700)
        #expect(OtherAnswerText.sendable(long)?.count == OtherAnswerText.maximumLength)
        #expect(OtherAnswerText.note(for: long) == "Only the first 500 characters are sent.")
    }

    @Test func theNoteAppearsOnlyWhenLineBreaksWillBeFlattened() {
        #expect(OtherAnswerText.note(for: "one line") == nil)
        #expect(OtherAnswerText.note(for: "  padded  ") == nil)
        #expect(OtherAnswerText.note(for: "a\nb") == "Line breaks are sent as spaces: the agent's answer field is one line.")
        #expect(OtherAnswerText.note(for: "trailing newline only\n") == nil)
    }
}
