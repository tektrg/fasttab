import Testing
@testable import AgentBar

struct StatusTextCleanerTests {
    @Test func stripsBordersAndCollapsesWhitespace() {
        #expect(StatusTextCleaner.singleLine("│ Should it  persist │ or not?", maxLength: 100) == "Should it persist or not?")
        #expect(StatusTextCleaner.singleLine("  line one\n  line two  ", maxLength: 100) == "line one line two")
    }

    @Test func emptyPlaceholderAndBarePromptGlyphAreNil() {
        #expect(StatusTextCleaner.singleLine(nil, maxLength: 10) == nil)
        #expect(StatusTextCleaner.singleLine("   ", maxLength: 10) == nil)
        #expect(StatusTextCleaner.singleLine("┃         ┃", maxLength: 10) == nil)
        #expect(StatusTextCleaner.singleLine("(no readable content)", maxLength: 100) == nil)
        #expect(StatusTextCleaner.singleLine("❯ ", maxLength: 10) == nil)
    }

    @Test func truncatesWithEllipsis() {
        let cleaned = StatusTextCleaner.singleLine("abcdefghij", maxLength: 5)
        #expect(cleaned == "abcd…")
        #expect(StatusTextCleaner.singleLine("abcde", maxLength: 5) == "abcde")
    }
}
