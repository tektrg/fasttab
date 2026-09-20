import Foundation
import Testing
@testable import AgentBar

/// Reading the plan file a plan-approval box names: read-only, capped, `~` expanded, never fatal.
struct PlanFileReaderTests {
    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("plan-reader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude/plans"), withIntermediateDirectories: true)
        return home
    }

    private func write(_ text: String, to relative: String, in home: URL) throws {
        try Data(text.utf8).write(to: home.appendingPathComponent(relative))
    }

    private func fixtureText() throws -> String {
        let url = try #require(Bundle.module.url(forResource: "plan-fixture", withExtension: "md", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func expandsTildeAgainstTheHomeFolderAndReadsTheWholeFile() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let text = try fixtureText()
        try write(text, to: ".claude/plans/nice-plan.md", in: home)
        #expect(PlanFileReader.read(path: "~/.claude/plans/nice-plan.md", home: home) == .text(text, truncated: false))
    }

    @Test func anAbsolutePathIsReadAsIs() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write("# tiny", to: ".claude/plans/a.md", in: home)
        let absolute = home.appendingPathComponent(".claude/plans/a.md").path
        #expect(PlanFileReader.read(path: absolute, home: home) == .text("# tiny", truncated: false))
    }

    @Test func noPathIsSaidPlainly() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(PlanFileReader.read(path: nil, home: home) == .noPath)
        #expect(PlanFileReader.read(path: "", home: home) == .noPath)
    }

    @Test func aMissingFileIsUnreadableWithTheReasonNotAnError() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        guard case .unreadable(let reason) = PlanFileReader.read(path: "~/.claude/plans/gone.md", home: home) else {
            Issue.record("expected unreadable")
            return
        }
        #expect(reason.contains("gone.md"))
    }

    @Test func aFolderIsNotAPlanFile() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        guard case .unreadable = PlanFileReader.read(path: "~/.claude/plans", home: home) else {
            Issue.record("expected unreadable")
            return
        }
    }

    @Test func aNamedPipeIsNotReadAndNeverBlocks() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let pipe = home.appendingPathComponent(".claude/plans/pipe.md").path
        #expect(mkfifo(pipe, 0o600) == 0)
        guard case .unreadable = PlanFileReader.read(path: pipe, home: home) else {
            Issue.record("expected unreadable")
            return
        }
    }

    @Test func onlyMarkdownAndAbsoluteOrHomePathsAreRead() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write("secret", to: ".claude/plans/x.txt", in: home)
        for path in ["~/.claude/plans/x.txt", "relative/plan.md", "../plan.md"] {
            guard case .unreadable = PlanFileReader.read(path: path, home: home) else {
                Issue.record("expected unreadable for \(path)")
                continue
            }
        }
    }

    @Test func aHugeFileIsCutAtTheCapAndSaysSo() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let line = "0123456789abcdefghij0123456789abcdefghij\n"
        let huge = String(repeating: line, count: (PlanFileReader.maxBytes / line.utf8.count) * 3)
        try write(huge, to: ".claude/plans/huge.md", in: home)
        guard case .text(let shown, let truncated) = PlanFileReader.read(path: "~/.claude/plans/huge.md", home: home) else {
            Issue.record("expected text")
            return
        }
        #expect(truncated)
        #expect(shown.utf8.count <= PlanFileReader.maxBytes)
        #expect(shown.utf8.count > PlanFileReader.maxBytes - 8)
    }

    @Test func aCutInTheMiddleOfACharacterDoesNotLeaveGarbage() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let body = String(repeating: "é", count: PlanFileReader.maxBytes)   // 2 bytes each: the cap lands mid-character or on a boundary
        try write("a" + body, to: ".claude/plans/utf.md", in: home)
        guard case .text(let shown, true) = PlanFileReader.read(path: "~/.claude/plans/utf.md", home: home) else {
            Issue.record("expected truncated text")
            return
        }
        #expect(!shown.contains("\u{FFFD}"))
    }

    @Test func aBinaryLookingFileIsStillDrawnAsTextWithoutCrashing() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try Data([0xFF, 0xFE, 0x00, 0x41]).write(to: home.appendingPathComponent(".claude/plans/bin.md"))
        _ = PlanFileReader.read(path: "~/.claude/plans/bin.md", home: home)
    }

    @Test func anEmptyFileIsSaidPlainly() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write("  \n", to: ".claude/plans/empty.md", in: home)
        guard case .unreadable(let reason) = PlanFileReader.read(path: "~/.claude/plans/empty.md", home: home) else {
            Issue.record("expected unreadable")
            return
        }
        #expect(reason.contains("empty"))
    }
}
