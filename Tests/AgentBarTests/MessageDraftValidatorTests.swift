import Testing
@testable import AgentBar

struct MessageDraftValidatorTests {
    typealias V = MessageDraftValidator

    @Test func plainTextIsReadyAndTrimmed() {
        #expect(V.check("  fix the login bug  ") == .ready(text: "fix the login bug"))
    }

    @Test func emptyAndBlankDraftsAreEmpty() {
        #expect(V.check("") == .empty)
        #expect(V.check("   \n \n\t ") == .empty)
    }

    @Test func everyLineBreakBecomesOneSpace() {
        #expect(V.check("first\nsecond") == .ready(text: "first second"))
        #expect(V.check("first\r\nsecond\rthird") == .ready(text: "first second third"))
        #expect(V.check("first  \n\n\n  second\n") == .ready(text: "first second"))
        #expect(V.sanitized("a\u{2028}b") == "a b")
        #expect(V.sanitized("first\nsecond").contains("\n") == false)
    }

    @Test func lineBreaksAreReportedSoTheCardCanSayTheyAreFlattened() {
        #expect(V.sendsWithLineBreaksFlattened("a\nb"))
        #expect(!V.sendsWithLineBreaksFlattened("a b"))
    }

    @Test func aLeadingSlashIsRefusedAsASlashCommand() {
        #expect(V.check("/help") == .slashCommand)
        #expect(V.check("  /model opus") == .slashCommand)
        #expect(V.check("\n\n/help") == .slashCommand)   // the first real line leads once breaks collapse
    }

    // MARK: - /compact and /clear (2026-09-22): the two exceptions the dashboard now also accepts

    @Test func compactAndClearAreReadyExactly() {
        #expect(V.check("/compact") == .ready(text: "/compact"))
        #expect(V.check("/clear") == .ready(text: "/clear"))
        #expect(V.check("  /compact  ") == .ready(text: "/compact"))
    }

    @Test func compactIsReadyWithTrailingInstructions() {
        #expect(V.check("/compact keep the plan") == .ready(text: "/compact keep the plan"))
        #expect(V.check("\n/compact\nkeep the plan\n") == .ready(text: "/compact keep the plan"))
    }

    /// Asymmetric with `/compact` on purpose, mirroring the dashboard's `is_allowed_slash_command`
    /// (`_ALLOWED_SLASH_PREFIX` is `/compact ` only): `/clear` must be bare, never with trailing
    /// text — a client that accepted `/clear starting fresh` as ready would send it and the
    /// dashboard would then refuse it as a plain (unrecognised) slash command.
    @Test func clearWithTrailingTextIsStillRefused() {
        #expect(V.check("/clear starting fresh") == .slashCommand)
        #expect(V.check("\n/clear\nstarting fresh\n") == .slashCommand)
    }

    @Test func aWordThatOnlyStartsWithCompactOrClearIsStillASlashCommand() {
        #expect(V.check("/compactfoo") == .slashCommand)
        #expect(V.check("/clearish") == .slashCommand)
        #expect(V.check("/compacting") == .slashCommand)
    }

    @Test func aSlashInsideTextIsFine() {
        #expect(V.check("look at src/main.swift") == .ready(text: "look at src/main.swift"))
    }

    @Test func theCapIsTwoThousandCharactersInclusive() {
        let exactly = String(repeating: "a", count: V.maxLength)
        #expect(V.check(exactly) == .ready(text: exactly))
        #expect(V.check(exactly + "b") == .tooLong(over: 1))
    }

    @Test func theCapCountsWhatIsSentNotWhatIsTyped() {
        let padded = String(repeating: "a", count: V.maxLength) + "\n\n\n\n"
        #expect(V.check(padded) == .ready(text: String(repeating: "a", count: V.maxLength)))
    }

    @Test func theCounterAppearsNearTheLimit() {
        #expect(!V.showsCounter(for: String(repeating: "a", count: V.counterFromLength - 1)))
        #expect(V.showsCounter(for: String(repeating: "a", count: V.counterFromLength)))
        #expect(V.showsCounter(for: String(repeating: "a", count: V.maxLength + 50)))
    }
}
