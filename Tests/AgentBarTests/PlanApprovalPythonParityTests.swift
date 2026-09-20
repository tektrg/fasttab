import Foundation
import Testing
@testable import AgentBar

/// Edge cases of the plan-box parser whose expected result was taken from running the dashboard's
/// `parse_plan_approval_block` (AptusFit `classify_pane.py`, commits 2fd2d65 + b4d8a1d, 2026-09-20)
/// on the same screens. The Python is the contract: the echoed title and planPath must equal its output
/// or the dashboard's `_same_permission` refuses the decision.
struct PlanApprovalPythonParityTests {
    private static let title = "Claude has written up a plan and is ready to execute. Would you like to proceed?"
    private static let options = [
        "❯ 1. Yes, and use auto mode", "  2. Yes, manually approve edits",
        "  3. Tell Claude what to change", "     shift+tab to approve with this feedback",
    ]

    private func box(_ titleRows: [String] = [PlanApprovalPythonParityTests.title], footer: [String], blankBeforeFooter: Bool = true) -> [String] {
        titleRows + [""] + Self.options + (blankBeforeFooter ? [""] : []) + footer
    }

    private func path(of screen: [String]) throws -> String? {
        let read = try #require(PanePermissionReader.prompt(in: screen))
        #expect(read.kind == .plan)
        #expect(read.title == Self.title)
        #expect(read.options.count == 3)
        return read.planPath
    }

    @Test func twoFooterShapedRowsAreAmbiguousSoThePathIsNil() throws {
        // Python: last-match-wins would silently drop the real path; it refuses instead.
        let clobbered = box(footer: ["ctrl+g to edit in Vim · ~/.claude/plans/real-path.md", "", "ctrl+g to edit in Vim ·", "notes.md"])
        #expect(try path(of: clobbered) == nil)
        let twoReal = box(footer: ["ctrl+g to edit in Vim · ~/.claude/plans/a.md", "", "ctrl+g to edit in Vim · ~/.claude/plans/b.md"])
        #expect(try path(of: twoReal) == nil)
    }

    @Test func aFooterWithNoBlankRowBeforeItIsNotTheFooter() throws {
        #expect(try path(of: box(footer: ["ctrl+g to edit in Vim · ~/.claude/plans/x.md"], blankBeforeFooter: false)) == nil)
    }

    @Test func aPathStartedOnTheFooterRowAndContinuedBelowIsNotJoined() throws {
        // Python only continues a footer whose row ends at the "·"; a partial path on that row gives nil.
        #expect(try path(of: box(footer: ["ctrl+g to edit in Vim · ~/.claude/plans/abc-de", "f.md"])) == nil)
    }

    @Test func aTitleAcrossABlankRowIsStillTheTitle() throws {
        let screen = box(["Claude has written up a plan and is ready to execute.", "", "Would you like to proceed?"], footer: ["ctrl+g to edit in Vim · ~/.claude/plans/x.md"])
        #expect(try path(of: screen) == "~/.claude/plans/x.md")
    }

    @Test func aTitleOverThreeRowsAndAFooterOnTheNextRowRead() throws {
        let screen = box(["Claude has written up a plan and", "is ready to execute. Would you", "like to proceed?"], footer: ["ctrl+g to edit in Vim ·", "~/.claude/plans/x.md"])
        #expect(try path(of: screen) == "~/.claude/plans/x.md")
    }

    @Test func aPathSplitOverThreeFollowingRowsJoinsWithNoSpaceButNotOverFour() throws {
        #expect(try path(of: box(footer: ["ctrl+g to edit in Vim ·", "~/.claude/plans/aaa", "bbb", "ccc.md"])) == "~/.claude/plans/aaabbbccc.md")
        #expect(try path(of: box(footer: ["ctrl+g to edit in Vim ·", "~/.claude/plans/aaa", "bbb", "ccc", "ddd.md"])) == nil)
    }

    @Test func aFragmentWithASpaceOrChromeEndsThePathSearch() throws {
        #expect(try path(of: box(footer: ["ctrl+g to edit in Vim ·", "~/.claude/plans/aaa", "bbb ccc.md"])) == nil)
        #expect(try path(of: box(footer: ["ctrl+g to edit in Vim ·", "●"])) == nil)
        #expect(try path(of: box(footer: ["ctrl+g to edit in Vim ·"])) == nil)
        #expect(try path(of: box(footer: ["ctrl+g to edit in Vim · ~/.claude/plans/a.txt"])) == nil)
    }
}
