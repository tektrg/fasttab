import Foundation
import Testing
@testable import AgentBar

/// Finding the pending AskUserQuestion form in the tail of a session transcript.
struct AskUserQuestionExtractorTests {
    private func find(_ lines: [String], atFileStart: Bool = true) -> AskUserQuestionExtractor.Finding {
        AskUserQuestionExtractor.find(in: TranscriptFixtures.jsonl(lines), chunkStartsAtFileStart: atFileStart)
    }

    private func result(forId id: String = FormFixtures.realToolUseId) -> String {
        TranscriptFixtures.userToolResult("The user answered: ...", toolUseId: id)
    }

    @Test func theRealThreeQuestionCallIsPendingWithEveryQuestion() throws {
        guard case .pending(let form) = find([TranscriptFixtures.assistantText("hello"), FormFixtures.realCallLine]) else {
            Issue.record("expected a pending form"); return
        }
        #expect(form.toolUseId == FormFixtures.realToolUseId)
        #expect(form.questions.map(\.header) == ["Done means", "Comes back", "Alerts"])
        #expect(form.questions[0].question == "What should \"Done\" do to an agent?")
        #expect(form.questions[0].options.map(\.label) == ["Just clear it (Recommended)", "Close the worker too"])
        #expect(form.questions[0].options[0].description.hasPrefix("Hides the agent"))
        #expect(form.questions.allSatisfy { !$0.isMultiSelect })
    }

    @Test func aLaterToolResultForTheSameCallMakesItSettled() {
        #expect(find([FormFixtures.realCallLine, result()]) == .settled)
    }

    @Test func aResultForAnotherToolDoesNotSettleIt() {
        guard case .pending = find([FormFixtures.realCallLine, result(forId: "toolu_other")]) else {
            Issue.record("expected pending"); return
        }
    }

    @Test func aRejectedCallWithAResultLineIsSettledToo() {
        #expect(find([FormFixtures.realCallLine, result(), TranscriptFixtures.assistantText("ok, moving on")]) == .settled)
    }

    @Test func onlyTheNewestCallCounts() {
        let older = FormFixtures.realCallLine.replacingOccurrences(of: FormFixtures.realToolUseId, with: "toolu_older")
        // The older call is settled but the newest is open: the open one is the form.
        guard case .pending(let form) = find([older, result(forId: "toolu_older"), FormFixtures.realCallLine]) else {
            Issue.record("expected pending"); return
        }
        #expect(form.toolUseId == FormFixtures.realToolUseId)
        // The older one is open but the newest was answered: nothing is pending.
        #expect(find([older, FormFixtures.realCallLine, result()]) == .settled)
    }

    @Test func aMultiSelectQuestionIsReadAsSuch() {
        let line = TranscriptFixtures.toolUse("AskUserQuestion", input: ["questions": [
            ["question": "Which colors?", "header": "Colors", "multiSelect": true, "options": [["label": "Red", "description": "r"], ["label": "Blue", "description": "b"]]],
            ["question": "Which size?", "header": "Size", "multiSelect": false, "options": [["label": "S", "description": ""], ["label": "L"]]]
        ]])
        guard case .pending(let form) = find([line]) else { Issue.record("expected pending"); return }
        #expect(form.questions.map(\.isMultiSelect) == [true, false])
        #expect(form.questions[1].options[1].description == "")
    }

    @Test func aMalformedCallIsNotAForm() {
        let noQuestions = TranscriptFixtures.toolUse("AskUserQuestion", input: ["questions": []])
        let noOptions = TranscriptFixtures.toolUse("AskUserQuestion", input: ["questions": [["question": "Q?", "header": "H", "options": []]]])
        let noQuestionText = TranscriptFixtures.toolUse("AskUserQuestion", input: ["questions": [["header": "H", "options": [["label": "A"]]]]])
        let noLabel = TranscriptFixtures.toolUse("AskUserQuestion", input: ["questions": [["question": "Q?", "options": [["description": "x"]]]]])
        let noInput = TranscriptFixtures.toolUse("AskUserQuestion")
        for line in [noQuestions, noOptions, noQuestionText, noLabel, noInput] {
            #expect(find([line]) == .notFound)
        }
    }

    @Test func aBadFirstLineOfACutChunkIsDropped() {
        let cut = "…half a line with AskUserQuestion \"assistant\" in it"
        #expect(AskUserQuestionExtractor.find(in: Data((cut + "\n" + TranscriptFixtures.assistantText("hi") + "\n").utf8), chunkStartsAtFileStart: false) == .notFound)
    }

    @Test func sidechainAndUserLinesAreNotTheCall() {
        let sidechain = FormFixtures.realCallLine.replacingOccurrences(of: "\"isSidechain\": false", with: "\"isSidechain\": true")
        #expect(find([sidechain]) == .notFound)
        #expect(find([TranscriptFixtures.userToolResult()]) == .notFound)
        #expect(find([]) == .notFound)
    }

    @Test func garbageLinesAreSkipped() {
        guard case .pending = find(["not json at all \"assistant\" AskUserQuestion", FormFixtures.realCallLine, "{\"broken"]) else {
            Issue.record("expected pending"); return
        }
    }
}

/// The transcript reader widening its window until it finds (or rules out) a form.
struct PendingFormReaderTests {
    private func rig(lines: [String]) throws -> (SessionTranscriptReader, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("form-reader-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("-some-project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try TranscriptFixtures.jsonl(lines).write(to: folder.appendingPathComponent("sess-1.jsonl"))
        return (SessionTranscriptReader(projectsRoot: root), root)
    }

    @Test func findsThePendingFormEvenBeyondTheFirstWindow() throws {
        let filler = Array(repeating: TranscriptFixtures.assistantText(String(repeating: "x", count: 4000)), count: 100)   // ~400KB after it
        let (reader, root) = try rig(lines: [FormFixtures.realCallLine] + filler)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(reader.pendingQuestionForm(forSession: "sess-1")?.questions.count == 3)
    }

    @Test func aFormThatWasAnsweredIsNotReturned() throws {
        let (reader, root) = try rig(lines: [FormFixtures.realCallLine, TranscriptFixtures.userToolResult("done", toolUseId: FormFixtures.realToolUseId)])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(reader.pendingQuestionForm(forSession: "sess-1") == nil)
    }

    @Test func unknownSessionsAndUnsafeIdsGiveNothing() throws {
        let (reader, root) = try rig(lines: [FormFixtures.realCallLine])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(reader.pendingQuestionForm(forSession: "nope") == nil)
        #expect(reader.pendingQuestionForm(forSession: "../sess-1") == nil)
    }
}
