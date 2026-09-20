import Foundation
import Testing
@testable import AgentBar

/// The Swift reader against the dashboard's parser for the plan-approval box (Claude's plan mode).
/// `Fixtures/aptusfit-permission-screens.json` is a verbatim copy of AptusFit's
/// `scripts/tests/fixtures/permission-screens.json`: real pane captures plus what each of
/// `classify_pane`'s parsers returned for them. If that parser changes, copy the new file over
/// this one and re-port.
struct PlanApprovalReaderTests {
    private struct Capture: Decodable {
        let screen: String
        let parsePermissionOrPlanBlock: DashboardPermission?
        let parseQuestionBlock: DashboardQuestion?

        private enum CodingKeys: String, CodingKey {
            case screen
            case parsePermissionOrPlanBlock = "parse_permission_or_plan_block"
            case parseQuestionBlock = "parse_question_block"
        }
    }

    private struct Fixture: Decodable {
        let cases: [String: Capture]
    }

    private func captures() throws -> [String: Capture] {
        let url = try #require(Bundle.module.url(forResource: "aptusfit-permission-screens", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).cases
    }

    private func lines(_ capture: Capture) -> [String] {
        capture.screen.components(separatedBy: "\n")
    }

    /// The screen lines of the named capture.
    private func screen(_ name: String) throws -> [String] {
        let capture = try #require(try captures()[name], "no capture named \(name)")
        return lines(capture)
    }

    @Test func everyCaptureReadsExactlyAsTheDashboardReadsIt() throws {
        let all = try captures()
        #expect(all.count >= 6)
        for (name, capture) in all {
            #expect(PanePermissionReader.prompt(in: lines(capture)) == capture.parsePermissionOrPlanBlock?.prompt, "\(name)")
        }
    }

    @Test func theRealPlanBoxReadsAsAPlanWithItsPathAndVerbatimOptions() throws {
        let read = try #require(PanePermissionReader.prompt(in: screen("plan_approval_box")))
        #expect(read.kind == .plan)
        #expect(read.tool == "ExitPlanMode")
        #expect(read.detail == "")
        #expect(read.planPath == "~/.claude/plans/dapper-strolling-sprout.md")
        #expect(read.title == "Claude has written up a plan and is ready to execute. Would you like to proceed?")
        #expect(read.options.map(\.label) == ["Yes, and use auto mode", "Yes, manually approve edits", "Tell Claude what to change"])
        #expect(read.cursorIndex == 1)
    }

    @Test func theCursorOnTheFeedbackRowIsRead() throws {
        let read = try #require(PanePermissionReader.prompt(in: screen("plan_approval_box_cursor_on_feedback")))
        #expect(read.cursorIndex == 3)
    }

    @Test func aBoxWithNoFooterHasNoPlanPathNeverAGuess() throws {
        let read = try #require(PanePermissionReader.prompt(in: screen("plan_approval_box_no_plan_path")))
        #expect(read.kind == .plan)
        #expect(read.planPath == nil)
    }

    @Test func plainPermissionAndEditBoxesAreStillTheToolKind() throws {
        for name in ["plain_permission_box", "edit_confirmation_box"] {
            let read = try #require(PanePermissionReader.prompt(in: screen(name)), "\(name)")
            #expect(read.kind == .tool, "\(name)")
            #expect(read.planPath == nil, "\(name)")
        }
    }

    @Test func aQuestionPickerIsNeverAPlanBox() throws {
        let picker = try screen("ask_user_question_box")
        #expect(PanePermissionReader.prompt(in: picker) == nil)
        #expect(PaneQuestionReader.question(in: picker) != nil)
    }

    @Test func aPlanBoxIsNeverAQuestionPicker() throws {
        for name in ["plan_approval_box", "plan_approval_box_cursor_on_feedback", "plan_approval_box_no_plan_path"] {
            #expect(PaneQuestionReader.question(in: try screen(name)) == nil, "\(name)")
        }
    }

    @Test func aPlanTitleNextToAReviewScreenIsNotReadAsAPlanBox() {
        let screen = [
            "Claude has written up a plan and is ready to execute. Would you like to proceed?",
            "Review your answers",
            "❯ 1. Yes, and use auto mode",
            "  2. Yes, manually approve edits",
        ]
        #expect(PanePermissionReader.prompt(in: screen) == nil)
    }

    @Test func aPlanTitleWithOneOptionIsNotReadAsAPlanBox() {
        let screen = ["Claude has written up a plan and is ready to execute. Would you like to proceed?", "❯ 1. Yes, and use auto mode"]
        #expect(PanePermissionReader.prompt(in: screen) == nil)
    }

    @Test func aDifferentTitleIsNeverGuessedAsAPlanBox() {
        let screen = ["Claude has a plan. Proceed?", "❯ 1. Yes, and use auto mode", "  2. Yes, manually approve edits"]
        #expect(PanePermissionReader.prompt(in: screen) == nil)
    }

    @Test func aBypassPermissionsVariantReadsWhateverOptionsAreOnScreen() throws {
        let screen = [
            "Claude has written up a plan and is ready to execute. Would you like to proceed?", "",
            "❯ 1. Yes, and bypass permissions", "  2. Yes, manually approve edits", "  3. Tell Claude what to change", "",
            "ctrl+g to edit in Vim · ~/.claude/plans/x.md",
        ]
        let read = try #require(PanePermissionReader.prompt(in: screen))
        #expect(read.options.map(\.label) == ["Yes, and bypass permissions", "Yes, manually approve edits", "Tell Claude what to change"])
    }

    @Test func aScreenWithBoxAndUnrelatedTextAboveStillReads() throws {
        let screenWithHistory = ["some earlier output", "⏺ Bash(ls)", "  ⎿  done", ""] + (try screen("plan_approval_box"))
        #expect(PanePermissionReader.prompt(in: screenWithHistory)?.kind == .plan)
    }
}
