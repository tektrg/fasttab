import Foundation
import Testing
@testable import AgentBar

struct TranscriptTailScannerTests {
    typealias T = TranscriptFixtures

    private func scan(_ lines: [String], fromFileStart: Bool = true) -> TranscriptScan {
        TranscriptTailScanner.scan(T.jsonl(lines), chunkStartsAtFileStart: fromFileStart)
    }

    @Test func theLatestTextIsFoundPastThinkingToolUseAndUserLines() {
        let result = scan([
            T.assistantText("Older message"),
            T.assistantText("I have two options for the storage."),
            T.thinking(),
            T.askUserQuestion(),
            T.userToolResult(),
            T.housekeeping()
        ])
        #expect(result.latestMessage == "I have two options for the storage.")
    }

    @Test func aBlockOfTextAfterAnotherInOneLineOrderTakesTheNewest() {
        #expect(scan([T.assistantText("first"), T.assistantText("second")]).latestMessage == "second")
    }

    @Test func subAgentAndPlaceholderMessagesAreNotTheAgentsWords() {
        let result = scan([
            T.assistantText("The real message"),
            T.assistantText("sub-agent chatter", sidechain: true),
            T.assistantText("No response requested.", model: "<synthetic>")
        ])
        #expect(result.latestMessage == "The real message")
    }

    @Test func blankTextIsSkipped() {
        #expect(scan([T.assistantText("Real"), T.assistantText("  \n ")]).latestMessage == "Real")
    }

    @Test func noTextAnywhereGivesNoMessage() {
        #expect(scan([T.thinking(), T.askUserQuestion()]).latestMessage == nil)
        #expect(scan([]).latestMessage == nil)
    }

    @Test func aVeryLongMessageIsCutWithAnEllipsis() throws {
        let message = try #require(scan([T.assistantText(String(repeating: "x", count: 20_000))]).latestMessage)
        #expect(message.count == TranscriptTailScanner.maxMessageLength)
        #expect(message.hasSuffix("…"))
    }

    // MARK: - The cut first line

    @Test func theFirstLineOfATailChunkIsDroppedBecauseItIsCutShort() {
        let whole = T.jsonl([T.assistantText("Partial line you cannot trust"), T.assistantText("Whole line")])
        let cutMidFirstLine = whole.dropFirst(20)
        #expect(TranscriptTailScanner.scan(Data(cutMidFirstLine), chunkStartsAtFileStart: false).latestMessage == "Whole line")
        let onlyTheCutLine = Data(T.jsonl([T.assistantText("Partial line you cannot trust")]).dropFirst(20))
        #expect(TranscriptTailScanner.scan(onlyTheCutLine, chunkStartsAtFileStart: false).latestMessage == nil)
    }

    @Test func aChunkFromTheFileStartKeepsItsFirstLine() {
        #expect(scan([T.assistantText("Only line")], fromFileStart: true).latestMessage == "Only line")
    }

    @Test func garbageLinesAreSkipped() {
        let data = Data("not json {\n".utf8) + T.jsonl([T.assistantText("Fine")]) + Data("\"assistant\" broken {\n".utf8)
        #expect(TranscriptTailScanner.scan(data, chunkStartsAtFileStart: true).latestMessage == "Fine")
    }

    // MARK: - Plan candidates

    @Test func markdownFilesTheAgentWroteEditedOrReadComeNewestFirst() {
        let result = scan([
            T.toolUse("Write", path: "/repo/docs/old-plan.md"),
            T.toolUse("Read", path: "/repo/docs/spec.md"),
            T.toolUse("Edit", path: "/repo/docs/new-plan.md", input: ["old_string": "a", "new_string": "b"]),
            T.assistantText("Done")
        ])
        #expect(result.markdownPathCandidates == ["/repo/docs/new-plan.md", "/repo/docs/spec.md", "/repo/docs/old-plan.md"])
    }

    @Test(arguments: [
        "/repo/.claude/skills/x/SKILL.md", "/repo/CLAUDE.md", "/repo/README.md", "/tmp/scratch.md",
        "/private/tmp/scratch.md", "relative/plan.md", "/repo/src/main.swift", "/repo/plan.md.bak"
    ])
    func notesThatAreNeverAPlanAreSkipped(path: String) {
        #expect(!TranscriptTailScanner.isPlanCandidate(path))
        #expect(scan([T.toolUse("Write", path: path)]).markdownPathCandidates.isEmpty)
    }

    @Test func otherToolsAndRepeatsDoNotCount() {
        let result = scan([
            T.toolUse("Bash", input: ["command": "cat /repo/plan.md"]),
            T.toolUse("Grep", path: "/repo/notes.md"),
            T.toolUse("Read", path: "/repo/plan.md"),
            T.toolUse("Edit", path: "/repo/plan.md")
        ])
        #expect(result.markdownPathCandidates == ["/repo/plan.md"])
    }

    @Test func onlyTheFewestRecentCandidatesAreKept() {
        let lines = (1...20).map { T.toolUse("Read", path: "/repo/doc\($0).md") }
        #expect(scan(lines).markdownPathCandidates.count == TranscriptTailScanner.maxPlanCandidates)
        #expect(scan(lines).markdownPathCandidates.first == "/repo/doc20.md")
    }
}
