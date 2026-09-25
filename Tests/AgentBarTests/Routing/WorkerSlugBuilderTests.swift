import Foundation
import Testing
@testable import AgentBar

struct WorkerSlugBuilderTests {
    // MARK: - Regex compliance (mirrors AptusFit's `chief_dashboard_worker.py` `_SLUG_RE`)

    @Test func slugPatternMatchesAptusFitsOwnRegexLiterally() {
        #expect(WorkerSlugBuilder.slugPattern == "^[a-z0-9][a-z0-9._-]*$")
    }

    @Test func everyGeneratedSlugMatchesTheRegexAcrossAWideRangeOfInputs() {
        let inputs = [
            "Fix the login timeout bug",
            "UPPERCASE WORDS ONLY",
            "  leading and trailing whitespace  ",
            "punctuation!!! galore??? --- ...",
            "123 starts with digits",
            "Sửa lỗi đăng nhập 🔥🔥🔥",   // non-ASCII + emoji only
            "🔥🔥🔥",
            "",
            "   ",
            "a",
            String(repeating: "word ", count: 30),   // long input, must still truncate cleanly
        ]
        for input in inputs {
            let slug = WorkerSlugBuilder.makeSlug(from: input)
            #expect(WorkerSlugBuilder.isValid(slug), "slug \"\(slug)\" (from \"\(input)\") should match \(WorkerSlugBuilder.slugPattern)")
        }
    }

    @Test func isValidRejectsShapesAptusFitsRegexWouldReject() {
        #expect(!WorkerSlugBuilder.isValid(""))
        #expect(!WorkerSlugBuilder.isValid("-starts-with-hyphen"))
        #expect(!WorkerSlugBuilder.isValid(".starts-with-dot"))
        #expect(!WorkerSlugBuilder.isValid("Has-Uppercase"))
        #expect(!WorkerSlugBuilder.isValid("has space"))
        #expect(!WorkerSlugBuilder.isValid("has/slash"))
    }

    @Test func isValidAcceptsShapesAptusFitsRegexWouldAccept() {
        #expect(WorkerSlugBuilder.isValid("a"))
        #expect(WorkerSlugBuilder.isValid("9start-with-digit"))
        #expect(WorkerSlugBuilder.isValid("a.b_c-d"))
    }

    // MARK: - Kebab-case derivation

    @Test func derivesAKebabCaseBaseFromTheFirstFewWords() {
        let slug = WorkerSlugBuilder.makeSlug(from: "Fix the login timeout", randomSuffix: { "abcd" })
        #expect(slug == "fix-the-login-timeout-abcd")
    }

    @Test func nonAsciiPunctuationAndEmojiAreSeparatorsNotPartOfTheBase() {
        let slug = WorkerSlugBuilder.makeSlug(from: "fix: the—login (timeout) 🔥bug", randomSuffix: { "wxyz" })
        #expect(slug == "fix-the-login-timeout-bug-wxyz")
    }

    @Test func onlyTheFirstSixWordsAreKept() {
        let slug = WorkerSlugBuilder.makeSlug(from: "one two three four five six seven eight", randomSuffix: { "zzzz" })
        #expect(slug == "one-two-three-four-five-six-zzzz")
    }

    @Test func textWithNoAsciiAlphanumericContentFallsBackToAPlainWorkerSlug() {
        let slug = WorkerSlugBuilder.makeSlug(from: "🔥🔥🔥", randomSuffix: { "q1w2" })
        #expect(slug == "worker-q1w2")
    }

    @Test func emptyTextFallsBackToAPlainWorkerSlug() {
        let slug = WorkerSlugBuilder.makeSlug(from: "", randomSuffix: { "q1w2" })
        #expect(slug == "worker-q1w2")
    }

    @Test func lowercasesUppercaseWords() {
        let slug = WorkerSlugBuilder.makeSlug(from: "FIX Login BUG", randomSuffix: { "abcd" })
        #expect(slug == "fix-login-bug-abcd")
    }

    // MARK: - Collision suffix

    @Test func twoDraftsWithTheSameWordingGetDifferentSlugsWhenTheirSuffixesDiffer() {
        let first = WorkerSlugBuilder.makeSlug(from: "fix the login bug", randomSuffix: { "aaaa" })
        let second = WorkerSlugBuilder.makeSlug(from: "fix the login bug", randomSuffix: { "bbbb" })
        #expect(first != second)
        #expect(first == "fix-the-login-bug-aaaa")
        #expect(second == "fix-the-login-bug-bbbb")
    }

    @Test func theDefaultRandomSuffixVariesBetweenCalls() {
        // Not provably non-colliding (36^4 space), but collapsing to the same value on 20
        // consecutive real calls would indicate the default generator is broken, not unlucky.
        let slugs = (0..<20).map { _ in WorkerSlugBuilder.makeSlug(from: "same wording every time") }
        #expect(Set(slugs).count > 1)
    }
}
