import Foundation
import Testing
@testable import AgentBar

/// Reading the question off a pane's screen the way the dashboard does.
/// The screens are shaped like real ones captured from a herdr pane (2026-09-19):
/// the "visible" read cuts a long line at the pane's width, mid-word; the
/// "unwrapped" read the dashboard answers from does not.
struct PaneQuestionReaderTests {
    private static let rule = String(repeating: "─", count: 90)
    private static let longQuestion = "Should the sample setting persist to disk per workspace, or stay session-only and reset each time the app reopens, and also what about the many other settings that we have never discussed before in this long conversation?"

    private func screen(question: [String], title: String = "  ☐ Persist") -> [String] {
        [Self.rule, title] + question + ["  ❯ 1. Persist per workspace", "    2. Session only", "    3. Type something.", Self.rule, "  Enter to select"]
    }

    @Test func readsTitleAndQuestionFromAnUnwrappedScreen() {
        let lines = screen(question: [Self.longQuestion])
        #expect(PaneQuestionReader.identity(in: lines) == QuestionIdentity(title: "Persist", question: Self.longQuestion))
    }

    @Test func aLineCutMidWordByTheVisibleReadJoinsWithAStraySpace() {
        // What the status feed carries: "a" / "lso" split at the pane width.
        let cut = Self.longQuestion.replacingOccurrences(of: "also", with: "a\nlso").split(separator: "\n").map(String.init)
        let fromFeed = PaneQuestionReader.identity(in: screen(question: cut))
        #expect(fromFeed?.question.contains("a lso") == true)
        #expect(fromFeed != PaneQuestionReader.identity(in: screen(question: [Self.longQuestion])))
    }

    @Test func bordersDrawnInsideTheBoxStayInTheQuestionAsTheDashboardKeepsThem() {
        let lines = screen(question: ["│ Should the sample setting persist to disk per workspace, or stay session-only and reset", "│ each time the app reopens?"])
        #expect(PaneQuestionReader.identity(in: lines)?.question
            == "│ Should the sample setting persist to disk per workspace, or stay session-only and reset │ each time the app reopens?")
    }

    @Test func onlyTheLastPickerCountsAndOlderOnesAboveItsRuleAreIgnored() {
        let older = [Self.rule, "  ☐ Old title", "  Old question?", "  1. A", "  2. B", "  3. Type something.", Self.rule, "⏺ done"]
        let lines = older + screen(question: ["Which one?"])
        #expect(PaneQuestionReader.identity(in: lines) == QuestionIdentity(title: "Persist", question: "Which one?"))
    }

    @Test func aTabbedTitleIsCleanedOfItsGlyphsAndArrows() {
        let lines = screen(question: ["Which?"], title: "←  ☒ Test colors  ✔ Submit  →")
        #expect(PaneQuestionReader.identity(in: lines)?.title == "Test colors")
    }

    @Test func aTitleWithNoQuestionTextUsesItselfAsTheQuestion() {
        #expect(PaneQuestionReader.identity(in: screen(question: []))?.question == "Persist")
    }

    @Test func nothingIsReadFromAScreenWithoutAPicker() {
        #expect(PaneQuestionReader.identity(in: ["$ ls", "file.txt"]) == nil)
        #expect(PaneQuestionReader.identity(in: []) == nil)
    }

    @Test func aReviewScreenOrASinglePermissionBoxIsNotAQuestion() {
        let review = [Self.rule, "  ☐ Persist", "  Review your answers", "  ❯ 1. Submit answers", "    2. Cancel", Self.rule]
        #expect(PaneQuestionReader.identity(in: review) == nil)
        let permission = [Self.rule, " Do you want to proceed?", " ❯ 1. Yes", "   2. No", Self.rule]
        #expect(PaneQuestionReader.identity(in: permission) == nil)   // no ballot-box title
        let oneOption = [Self.rule, "  ☐ T", "  Q?", "  ❯ 1. Only", Self.rule]
        #expect(PaneQuestionReader.identity(in: oneOption) == nil)
    }

    @Test func footerAndChromeLinesAreNotPartOfTheQuestion() {
        let lines = [Self.rule, "  ☐ T", "  auto mode on", "  ✦ ✦", "Real question?", "  ❯ 1. A", "    2. B", Self.rule]
        #expect(PaneQuestionReader.identity(in: lines)?.question == "Real question?")
    }

    // MARK: - The whole picker, against the dashboard's parser

    private struct RecordedScreen: Decodable {
        struct Picker: Decodable {
            struct Option: Decodable {
                let index: Int
                let label: String
                let desc: String
                let checked: Bool
                let other: Bool
            }
            let title: String
            let question: String
            let multi: Bool
            let options: [Option]
        }
        let name: String
        let lines: [String]
        let expected: Picker?
    }

    private func recordedScreens() throws -> [RecordedScreen] {
        let url = try #require(Bundle.module.url(forResource: "question-screens", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode([RecordedScreen].self, from: Data(contentsOf: url))
    }

    /// `Fixtures/question-screens.json`: screens with what `classify_pane.parse_question_block` returned
    /// for them (generated by running the real parser). A picker with an option already ticked is
    /// one the panel leaves to the terminal, so there the reader must return nothing.
    @Test func everyRecordedScreenReadsAsTheDashboardReadsIt() throws {
        let all = try recordedScreens()
        #expect(all.count >= 20)
        for screen in all {
            let read = PaneQuestionReader.question(in: screen.lines)
            guard let expected = screen.expected, !expected.options.contains(where: \.checked) else {
                #expect(read == nil, "\(screen.name)")
                continue
            }
            #expect(read?.title == expected.title, "\(screen.name)")
            #expect(read?.question == expected.question, "\(screen.name)")
            #expect(read?.isMultiSelect == expected.multi, "\(screen.name)")
            let options = read?.options.map { "\($0.index)|\($0.label)|\($0.description)|\($0.isOther)" }
            #expect(options == expected.options.map { "\($0.index)|\($0.label)|\($0.desc)|\($0.other)" }, "\(screen.name)")
            #expect(read?.identity == PaneQuestionReader.identity(in: screen.lines), "\(screen.name)")
        }
    }

    @Test func aReadPickerIsAnAnswerableQuestionWithItsOptions() throws {
        let lines = screen(question: ["Which one?"])
        let read = try #require(PaneQuestionReader.question(in: lines))
        #expect(read.options.map(\.index) == [1, 2, 3])
        #expect(read.options.last?.isOther == true)
        #expect(read.identity == PaneQuestionReader.identity(in: lines))
    }
}
