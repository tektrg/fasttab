import Testing
@testable import AgentBar

struct PaneScreenTextTests {
    @Test func stripsColourAndCursorEscapes() {
        let raw = "\u{1B}[1;32mgreen\u{1B}[0m and \u{1B}[2K\u{1B}[10;5Hmoved"
        #expect(PaneScreenText.cleaned([raw]) == ["green and moved"])
    }

    @Test func stripsWindowTitleAndHyperlinkSequences() {
        let raw = "\u{1B}]0;title\u{07}text \u{1B}]8;;https://x.test\u{1B}\\link\u{1B}]8;;\u{1B}\\"
        #expect(PaneScreenText.cleaned([raw]) == ["text link"])
    }

    @Test func dropsControlCharactersAndBidiOverridesAndExpandsTabs() {
        let raw = "a\u{00}b\u{07}c\u{202E}d\td"
        #expect(PaneScreenText.cleaned([raw]) == ["abcd    d"])
    }

    @Test func keepsOrdinaryUnicodeAndBoxDrawing() {
        #expect(PaneScreenText.cleaned(["│ ✓ done — héllo 世界 │"]) == ["│ ✓ done — héllo 世界 │"])
    }

    @Test func cutsVeryLongLinesWithAnEllipsis() {
        let cleaned = PaneScreenText.cleaned([String(repeating: "x", count: 5_000)])
        #expect(cleaned[0].count == PaneScreenText.maxLineLength)
        #expect(cleaned[0].hasSuffix("…"))
    }

    @Test func keepsOnlyTheNewestLinesAndDropsTrailingBlankOnes() {
        let raw = (1...100).map { "line \($0)" } + ["", "   ", ""]
        let cleaned = PaneScreenText.cleaned(raw)
        #expect(cleaned.count == PaneScreenText.maxLineCount)
        #expect(cleaned.last == "line 100")
        #expect(cleaned.first == "line 61")
    }

    @Test func shortensLongGapsBetweenWordsButKeepsIndentation() {
        let raw = "    indented" + String(repeating: " ", count: 60) + "right side"
        #expect(PaneScreenText.cleaned([raw]) == ["    indented    right side"])
    }

    @Test func keepsBlankLinesInTheMiddle() {
        #expect(PaneScreenText.cleaned(["a", "", "b"]) == ["a", "", "b"])
    }

    @Test func aScreenOfNothingCleansToNothing() {
        #expect(PaneScreenText.cleaned([]) == [])
        #expect(PaneScreenText.cleaned(["", " \u{1B}[0m "]) == [])
    }
}
