import Foundation
import Testing
@testable import AgentBar

/// The picker states the plain parser cannot express: the terminal cursor on the exit row (`Submit` / `Next`)
/// and a multi-select with options already ticked. Both are pickers someone is answering right now.
/// Fixtures are a real user screen (2026-09-20, glyphs reconstructed) and the same form freshly opened.
struct PaneQuestionReaderExitRowTests {
    private static let rule = String(repeating: "─", count: 90)
    private static let wantedIdentityTitle = "How to finish Record findings"
    private static let wantedQuestion = "Three findings currently exist only in this conversation. Which should I write up as durable records before anything else?"

    static func fixtureLines(_ name: String) -> [String] {
        let url = Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures")!
        return try! String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
    }

    private var cursorOnSubmit: [String] { Self.fixtureLines("user-multi-select-cursor-on-submit") }
    private var freshCursorOnFirstOption: [String] { Self.fixtureLines("same-form-fresh-cursor-on-opt1") }
    private let identity = QuestionIdentity(title: Self.wantedIdentityTitle, question: Self.wantedQuestion)

    /// A single-select picker with the cursor on `Next`, nothing ticked.
    private func singleSelect(cursorOnExitRow: Bool) -> [String] {
        [Self.rule, "  ←  ☐ Fruit  ☐ Colour  ✔ Submit  →", "Which fruit?", "",
         "    1. Apple", "    2. Banana", "    3. Type something.",
         cursorOnExitRow ? "  ❯ Next" : "    Next", Self.rule, "  Enter to select"]
    }

    @Test func pickerOnSubmitRowIsRecognisedNotNil() {
        // The cursor is on Submit: there is no `❯ <digit>.` line anywhere, yet a picker is open.
        #expect(PaneQuestionReader.identity(in: cursorOnSubmit) == identity)
        guard case .onExitRow(let read) = PaneQuestionReader.openPickerState(in: singleSelect(cursorOnExitRow: true)) else {
            Issue.record("expected .onExitRow"); return
        }
        #expect(read == QuestionIdentity(title: "Fruit Colour", question: "Which fruit?"))
        #expect(PaneQuestionReader.identity(in: singleSelect(cursorOnExitRow: true)) == read)
    }

    @Test func theRealUserScreenReadsAsTheExitRowStateWithItsIdentity() {
        // ticks AND the cursor on Submit: the exit row is what says "the user is at the end of this question".
        #expect(PaneQuestionReader.openPickerState(in: cursorOnSubmit) == .onExitRow(identity))
    }

    @Test func tickedMultiSelectIsNotAnAnswerablePickerButIsOpen() {
        var ticked = freshCursorOnFirstOption
        ticked = ticked.map { $0.replacingOccurrences(of: "2. [ ] Plan", with: "2. [✔] Plan") }
        #expect(PaneQuestionReader.question(in: ticked) == nil)                 // not answerable from the panel
        #expect(PaneQuestionReader.openPickerState(in: ticked) == .hasTicks(identity))
        #expect(PaneQuestionReader.identity(in: ticked) == identity)            // but open, for the Message guard
    }

    @Test func aFreshMultiSelectWithTheCursorOnTheFirstOptionIsOpenAndAnswerable() throws {
        guard case .open(let question) = PaneQuestionReader.openPickerState(in: freshCursorOnFirstOption) else {
            Issue.record("expected .open"); return
        }
        #expect(question == PaneQuestionReader.question(in: freshCursorOnFirstOption))
        #expect(question.isMultiSelect)
        #expect(question.identity == identity)
        #expect(question.options.map(\.index) == [1, 2, 3, 4, 5])
        #expect(question.options.last?.isOther == true)
    }

    @Test func chatAboutThisAfterSubmitRowIsNotAnOption() throws {
        // As drawn: a rule sits between the Submit row and "Chat about this".
        let drawn = try #require(PaneQuestionReader.question(in: freshCursorOnFirstOption))
        #expect(!drawn.options.contains { $0.label.contains("Chat about this") })
        // Without that rule the row would sit in the same block: still never an option.
        let noRule = freshCursorOnFirstOption.enumerated().filter { !($0.offset > 10 && $0.element.hasPrefix("──")) }.map(\.element)
        #expect(noRule.count == freshCursorOnFirstOption.count - 1)
        let merged = try #require(PaneQuestionReader.question(in: noRule))
        #expect(merged.options.map(\.label) == drawn.options.map(\.label))
        #expect(merged.options.filter(\.isOther).count == 1)
    }

    @Test func aReviewScreenAndAScreenWithoutAPickerAreNotPickers() {
        #expect(PaneQuestionReader.openPickerState(in: FormFixtures.reviewScreen(FormFixtures.form())) == .review)
        #expect(PaneQuestionReader.openPickerState(in: FormFixtures.goneScreen) == .none)
        #expect(PaneQuestionReader.identity(in: FormFixtures.goneScreen) == nil)
        // A prompt line that merely reads "❯ Next" is not a picker.
        #expect(PaneQuestionReader.openPickerState(in: ["⏺ done", "", "❯ Next"]) == .none)
    }

    @Test func aNormalScreenStillReadsExactlyAsBefore() {
        let lines = FormFixtures.screen(FormFixtures.form(), tab: 1)
        guard case .open(let question) = PaneQuestionReader.openPickerState(in: lines) else { Issue.record("expected .open"); return }
        #expect(question == PaneQuestionReader.question(in: lines))
        #expect(PaneQuestionReader.identity(in: lines) == question.identity)
    }

    /// Differential: on every screen recorded from the dashboard's real Python parser, the new reader agrees with
    /// it (and with the old reader): unticked = open with the same picker, ticked = open-but-not-answerable.
    @Test func theStateReaderAgreesWithTheRecordedPythonScreens() throws {
        struct Recorded: Decodable {
            struct Picker: Decodable {
                struct Option: Decodable { let checked: Bool }
                let title: String
                let question: String
                let options: [Option]
            }
            let name: String
            let lines: [String]
            let expected: Picker?
        }
        let url = try #require(Bundle.module.url(forResource: "question-screens", withExtension: "json", subdirectory: "Fixtures"))
        let all = try JSONDecoder().decode([Recorded].self, from: Data(contentsOf: url))
        for screen in all {
            let state = PaneQuestionReader.openPickerState(in: screen.lines)
            switch screen.expected {
            case nil:
                #expect(state == .none || state == .review, "\(screen.name)")
                #expect(PaneQuestionReader.identity(in: screen.lines) == nil, "\(screen.name)")
            case let expected?:
                let wanted = QuestionIdentity(title: expected.title, question: expected.question)
                if expected.options.contains(where: \.checked) {
                    #expect(state == .hasTicks(wanted) || state == .onExitRow(wanted), "\(screen.name)")
                } else {
                    guard case .open(let question) = state else { Issue.record("\(screen.name): \(state)"); continue }
                    #expect(question == PaneQuestionReader.question(in: screen.lines), "\(screen.name)")
                    #expect(question.identity == wanted, "\(screen.name)")
                }
                #expect(PaneQuestionReader.identity(in: screen.lines) == wanted, "\(screen.name)")
            }
        }
    }
}
