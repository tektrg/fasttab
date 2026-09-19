import Foundation
import Testing
@testable import AgentBar

struct SessionTranscriptReaderTests {
    typealias T = TranscriptFixtures

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentBarTranscripts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @discardableResult
    private func writeTranscript(_ lines: [String], session: String, folder: String, in root: URL) throws -> URL {
        let directory = root.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(session).jsonl")
        try T.jsonl(lines).write(to: file)
        return file
    }

    /// Lines that are none of the reader's business, as big as tool output can be.
    private func bulk(megabytes: Double) -> [String] {
        let line = T.userToolResult(String(repeating: "y", count: 10_000))
        return Array(repeating: line, count: Int(megabytes * 100))
    }

    @Test func findsTheTranscriptInAnyProjectFolderBySessionId() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeTranscript([T.assistantText("in the wrong-looking folder")], session: "abc-123", folder: "-Users-someone-odd", in: root)
        try writeTranscript([T.assistantText("other")], session: "zzz", folder: "-Users-else", in: root)
        let context = SessionTranscriptReader(projectsRoot: root).context(forSession: "abc-123")
        #expect(context.latestMessage == "in the wrong-looking folder")
    }

    @Test func aMissingTranscriptOrFolderGivesNothing() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(SessionTranscriptReader(projectsRoot: root).context(forSession: "nope") == .empty)
        #expect(SessionTranscriptReader(projectsRoot: root.appendingPathComponent("absent")).context(forSession: "nope") == .empty)
    }

    @Test func aSessionIdCannotWalkOutOfTheFolder() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeTranscript([T.assistantText("secret")], session: "target", folder: "p", in: root)
        let reader = SessionTranscriptReader(projectsRoot: root.appendingPathComponent("p"))
        #expect(reader.context(forSession: "../p/target") == .empty)
        #expect(!SessionTranscriptReader.isSafeFileStem("a/b"))
        #expect(!SessionTranscriptReader.isSafeFileStem(""))
        #expect(SessionTranscriptReader.isSafeFileStem("0f1e2d3c-4b5a-4678-9abc-def012345678"))
    }

    @Test func findsTheLatestMessageInAFileFarLargerThanTheFirstWindow() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // ~3MB of bulk BEFORE the message: a whole-file read would find the old text too.
        let lines = [T.assistantText("ancient message")] + bulk(megabytes: 3) + [T.assistantText("fresh message"), T.askUserQuestion()]
        try writeTranscript(lines, session: "big", folder: "p", in: root)
        #expect(SessionTranscriptReader(projectsRoot: root).context(forSession: "big").latestMessage == "fresh message")
    }

    @Test func growsTheWindowWhenTheLastTextIsBuriedUnderBigToolOutput() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // The last text is ~2MB from the end: past the 256KB and 1MB windows, inside 4MB.
        let lines = [T.assistantText("buried message")] + bulk(megabytes: 2) + [T.askUserQuestion()]
        try writeTranscript(lines, session: "buried", folder: "p", in: root)
        #expect(SessionTranscriptReader(projectsRoot: root).context(forSession: "buried").latestMessage == "buried message")
    }

    @Test func givesUpPastTheLargestWindowInsteadOfReadingTheWholeFile() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let lines = [T.assistantText("far too old")] + bulk(megabytes: 5) + [T.askUserQuestion()]
        try writeTranscript(lines, session: "ancient", folder: "p", in: root)
        #expect(SessionTranscriptReader(projectsRoot: root).context(forSession: "ancient").latestMessage == nil)
    }

    @Test func aPlanLinkIsOnlyAFileThatExists() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let realPlan = root.appendingPathComponent("real-plan.md")
        try Data("# plan".utf8).write(to: realPlan)
        let missing = root.appendingPathComponent("deleted-plan.md").path
        // The newest candidate is gone, an older one is still on disk.
        try writeTranscript([
            T.toolUse("Write", path: realPlan.path),
            T.toolUse("Write", path: missing),
            T.assistantText("Here is the plan")
        ], session: "plans", folder: "p", in: root)
        let context = SessionTranscriptReader(projectsRoot: root).context(forSession: "plans")
        #expect(context.planFile?.path == realPlan.path)
    }

    @Test func aFolderNamedLikeAPlanIsNotOne() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("docs.md")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try writeTranscript([T.toolUse("Read", path: folder.path), T.assistantText("x")], session: "dir", folder: "p", in: root)
        #expect(SessionTranscriptReader(projectsRoot: root).context(forSession: "dir").planFile == nil)
    }
}
