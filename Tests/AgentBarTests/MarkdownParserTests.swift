import Foundation
import Testing
@testable import AgentBar

struct MarkdownParserTests {
    typealias Block = MarkdownBlock

    // MARK: - Realistic agent messages

    @Test func aTypicalReplyIsHeadingParagraphsListAndCode() {
        let message = """
        ## Summary

        I fixed the **flaky test** by awaiting the `loader` before asserting.
        It now passes 20/20 runs.

        Changes:
        - Added `waitUntil` helper
        - Removed the fixed `sleep`

        ```swift
        let ready = await waitUntil { model.isReady }
        ```

        Run `swift test` to confirm.
        """
        #expect(MarkdownParser.parse(message) == [
            .heading(level: 2, text: "Summary"),
            .paragraph("I fixed the **flaky test** by awaiting the `loader` before asserting.\nIt now passes 20/20 runs."),
            .paragraph("Changes:"),
            .listItem(depth: 0, marker: .bullet, text: "Added `waitUntil` helper"),
            .listItem(depth: 0, marker: .bullet, text: "Removed the fixed `sleep`"),
            .codeBlock(language: "swift", code: "let ready = await waitUntil { model.isReady }"),
            .paragraph("Run `swift test` to confirm."),
        ])
    }

    @Test func aListRightAfterAParagraphLineNeedsNoBlankLine() {
        #expect(MarkdownParser.parse("Options:\n1. one\n2. two") == [
            .paragraph("Options:"),
            .listItem(depth: 0, marker: .number(1), text: "one"),
            .listItem(depth: 0, marker: .number(2), text: "two"),
        ])
    }

    // MARK: - Headings, rules, paragraphs

    @Test func headingLevelsAndClosingHashes() {
        #expect(MarkdownParser.parse("# One\n###### Six ##") == [.heading(level: 1, text: "One"), .heading(level: 6, text: "Six")])
    }

    @Test func aHashWithoutASpaceOrTextIsNotAHeading() {
        #expect(MarkdownParser.parse("#hashtag\n#\n####### seven") == [.paragraph("#hashtag\n#\n####### seven")])
    }

    @Test func horizontalRules() {
        #expect(MarkdownParser.parse("above\n\n---\n\n***\nbelow") == [.paragraph("above"), .rule, .rule, .paragraph("below")])
    }

    @Test func emptyAndBlankInputGiveNoBlocks() {
        #expect(MarkdownParser.parse("").isEmpty)
        #expect(MarkdownParser.parse("  \n\n \t\n").isEmpty)
    }

    @Test func windowsLineEndingsAreLineBreaks() {
        #expect(MarkdownParser.parse("a\r\nb\r\n\r\nc") == [.paragraph("a\nb"), .paragraph("c")])
    }

    // MARK: - Lists

    @Test func nestedListsGetDepthFromIndentWhateverTheStep() {
        let twoSpaces = "- a\n  - b\n    - c\n- d"
        let fourSpaces = "- a\n    - b\n        - c\n- d"
        let expected: [Block] = [
            .listItem(depth: 0, marker: .bullet, text: "a"),
            .listItem(depth: 1, marker: .bullet, text: "b"),
            .listItem(depth: 2, marker: .bullet, text: "c"),
            .listItem(depth: 0, marker: .bullet, text: "d"),
        ]
        #expect(MarkdownParser.parse(twoSpaces) == expected)
        #expect(MarkdownParser.parse(fourSpaces) == expected)
    }

    @Test func numberedListKeepsItsNumbersAndMixesWithBulletsWhenNested() {
        #expect(MarkdownParser.parse("3. three\n   * sub\n4) four") == [
            .listItem(depth: 0, marker: .number(3), text: "three"),
            .listItem(depth: 1, marker: .bullet, text: "sub"),
            .listItem(depth: 0, marker: .number(4), text: "four"),
        ])
    }

    @Test func anIndentedLineAfterAnItemContinuesIt() {
        #expect(MarkdownParser.parse("- first line\n  second line\n- next") == [
            .listItem(depth: 0, marker: .bullet, text: "first line\nsecond line"),
            .listItem(depth: 0, marker: .bullet, text: "next"),
        ])
    }

    @Test func taskListBoxesBecomeSymbols() {
        #expect(MarkdownParser.parse("- [ ] todo\n- [x] done") == [
            .listItem(depth: 0, marker: .bullet, text: "☐ todo"),
            .listItem(depth: 0, marker: .bullet, text: "☑ done"),
        ])
    }

    @Test func dashesAndNumbersThatAreNotListsStayText() {
        #expect(MarkdownParser.parse("-5 degrees\n2024.5 was fine\n-") == [.paragraph("-5 degrees\n2024.5 was fine\n-")])
    }

    @Test func aListEndsAtAnUnindentedParagraph() {
        #expect(MarkdownParser.parse("- a\n  - b\n\nDone.\n- c") == [
            .listItem(depth: 0, marker: .bullet, text: "a"),
            .listItem(depth: 1, marker: .bullet, text: "b"),
            .paragraph("Done."),
            .listItem(depth: 0, marker: .bullet, text: "c"),
        ])
    }

    // MARK: - Code

    @Test func codeFenceKeepsLanguageBlankLinesAndMarkdownLookingLines() {
        let message = "```json\n{\n\n  \"a\": 1\n}\n# not a heading\n- not a list\n```"
        #expect(MarkdownParser.parse(message) == [
            .codeBlock(language: "json", code: "{\n\n  \"a\": 1\n}\n# not a heading\n- not a list")
        ])
    }

    @Test func aFenceWithoutALanguageAndTildeFences() {
        #expect(MarkdownParser.parse("```\nplain\n```\n~~~sh extra words\nls\n~~~") == [
            .codeBlock(language: nil, code: "plain"),
            .codeBlock(language: "sh", code: "ls"),
        ])
    }

    @Test func aLongerFenceIsNotClosedByAShorterOne() {
        #expect(MarkdownParser.parse("````md\n```\ninner\n```\n````") == [.codeBlock(language: "md", code: "```\ninner\n```")])
    }

    @Test func anUnterminatedFenceRunsToTheEnd() {
        #expect(MarkdownParser.parse("Before\n```python\nprint(1)\nprint(2)") == [
            .paragraph("Before"),
            .codeBlock(language: "python", code: "print(1)\nprint(2)"),
        ])
    }

    @Test func aFenceInsideAListItemLosesItsIndent() {
        #expect(MarkdownParser.parse("1. Run:\n   ```sh\n   make\n     all\n   ```\n2. Done") == [
            .listItem(depth: 0, marker: .number(1), text: "Run:"),
            .codeBlock(language: "sh", code: "make\n  all"),
            .listItem(depth: 0, marker: .number(2), text: "Done"),
        ])
    }

    @Test func tripleBackticksOnOneLineAreInlineCodeNotAFence() {
        #expect(MarkdownParser.parse("```inline``` then text") == [.paragraph("```inline``` then text")])
    }

    // MARK: - Quotes

    @Test func quotesHoldBlocksAndNest() {
        #expect(MarkdownParser.parse("> **Note**\n> - a\n> > deeper\n\nafter") == [
            .quote([
                .paragraph("**Note**"),
                .listItem(depth: 0, marker: .bullet, text: "a"),
                .quote([.paragraph("deeper")]),
            ]),
            .paragraph("after"),
        ])
    }

    @Test func quoteNestingIsCapped() {
        let blocks = MarkdownParser.parse("> > > > > deep")
        var depth = 0
        var current = blocks
        while case .quote(let inner)? = current.first { depth += 1; current = inner }
        #expect(depth == MarkdownParser.maxQuoteDepth + 1)   // the last level is plain text, never recursed further
        #expect(current == [.paragraph("> deep")])
    }

    // MARK: - Tables

    @Test func aTableHasHeaderAndRowsWithoutTheDelimiterLine() {
        let message = """
        | File | Change |
        |------|:------:|
        | `a.swift` | new |
        | b.swift | edited \\| escaped |

        After.
        """
        #expect(MarkdownParser.parse(message) == [
            .table(header: ["File", "Change"], rows: [["`a.swift`", "new"], ["b.swift", "edited | escaped"]]),
            .paragraph("After."),
        ])
    }

    @Test func tableRowsAreMadeAsWideAsTheHeader() {
        #expect(MarkdownParser.parse("a | b\n- | -\n1 |\n1 | 2 | 3") == [
            .table(header: ["a", "b"], rows: [["1", ""], ["1", "2"]])
        ])
    }

    @Test func aPipeLineWithoutADelimiterRowIsProse() {
        #expect(MarkdownParser.parse("use a | b here\nnext line") == [.paragraph("use a | b here\nnext line")])
    }

    @Test func tableSizeIsCapped() {
        let columns = MarkdownParser.maxTableColumns + 5
        let header = (0..<columns).map { "h\($0)" }.joined(separator: " | ")
        let delimiter = (0..<columns).map { _ in "---" }.joined(separator: " | ")
        let rows = (0..<(MarkdownParser.maxTableRows + 20)).map { "\($0) | x" }.joined(separator: "\n")
        guard case .table(let parsedHeader, let parsedRows)? = MarkdownParser.parse("\(header)\n\(delimiter)\n\(rows)").first else {
            Issue.record("expected a table"); return
        }
        #expect(parsedHeader.count == MarkdownParser.maxTableColumns)
        #expect(parsedRows.count == MarkdownParser.maxTableRows)
        #expect(parsedRows.allSatisfy { $0.count == MarkdownParser.maxTableColumns })
    }

    // MARK: - Malformed and huge input

    @Test func aVeryLongLineIsOneParagraphAndHugeInputIsCutWithANote() {
        let longLine = String(repeating: "word ", count: 2_000)   // 10k characters, no breaks
        #expect(MarkdownParser.parse(longLine).count == 1)

        let huge = String(repeating: "line of text\n\n", count: 10_000)
        let blocks = MarkdownParser.parse(huge)
        #expect(blocks.count <= MarkdownParser.maxBlocks + 1)
        #expect(blocks.last == .paragraph(MarkdownParser.truncationNote))
    }

    @Test func aHugeUnterminatedFenceStaysWithinTheCharacterCap() {
        let blocks = MarkdownParser.parse("```\n" + String(repeating: "x", count: 500_000))
        guard case .codeBlock(_, let code)? = blocks.first else { Issue.record("expected code"); return }
        #expect(code.count <= MarkdownParser.maxCharacters)
        #expect(blocks.last == .paragraph(MarkdownParser.truncationNote))
    }

    @Test func garbageNeverCrashesAndAlwaysProducesBlocks() {
        for junk in ["|||\n|-|\n|", "> \n>\n> >", "```", "~~~~~~", "#", "- \n1.\n2)", "\u{0}\u{1}", "* * *", "| a |\n|:-:|", "\\", "**unclosed *mix `code"] {
            _ = MarkdownParser.parse(junk)
        }
        #expect(MarkdownParser.parse("**unclosed *mix `code") == [.paragraph("**unclosed *mix `code")])
    }
}

struct MarkdownInlineTests {
    private func text(_ attributed: AttributedString) -> String { String(attributed.characters) }

    @Test func boldItalicAndCodeKeepTheirWordsAndCarryTheirStyle() {
        let result = MarkdownInline.attributed("a **bold** *it* `code`")
        #expect(text(result) == "a bold it code")
        let intents = result.runs.compactMap { run in run.inlinePresentationIntent.map { (String(result[run.range].characters), $0) } }
        #expect(intents.contains { $0.0 == "bold" && $0.1.contains(.stronglyEmphasized) })
        #expect(intents.contains { $0.0 == "it" && $0.1.contains(.emphasized) })
        #expect(intents.contains { $0.0 == "code" && $0.1.contains(.code) })
    }

    @Test func lineBreaksAndSpacingInsideAParagraphAreKept() {
        #expect(text(MarkdownInline.attributed("one\ntwo  three")) == "one\ntwo  three")
    }

    @Test func webLinksStayClickableOthersKeepTheirTextOnly() {
        let result = MarkdownInline.attributed("[site](https://example.com) [file](file:///etc/passwd) [rel](docs/a.md) [mail](mailto:a@b.co)")
        #expect(text(result) == "site file rel mail")
        let links = result.runs.compactMap { run in run.link.map { (String(result[run.range].characters), $0.absoluteString) } }
        #expect(links.map(\.0) == ["site", "mail"])
    }

    @Test func unreadableMarkdownFallsBackToTheRawText() {
        #expect(text(MarkdownInline.attributed("[broken](")).contains("broken"))
        #expect(text(MarkdownInline.attributed("")) == "")
    }
}
