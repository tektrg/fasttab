import Foundation
import Testing
@testable import AgentBar

/// Herdr panes are 76 columns wide, so Claude's plan-approval box wraps its own text: the title over two
/// rows, the footer path on a row of its own. The dashboard's parser is being taught the same tolerance
/// (AptusFit brief `dashboard-plan-box-wrapped`); the identity sent at send time (title + path + rows) must
/// be the same for a wrapped and a wide drawing of the same box, or the dashboard refuses the decision.
/// The fixtures are real /api/pane/screen captures (2026-09-20).
struct PlanApprovalWrappedTests {
    private static let title = "Claude has written up a plan and is ready to execute. Would you like to proceed?"
    private static let path = "~/.claude/plans/nudge-206c9c93-from-77c13531-66be-4cab-foamy-hopper.md"
    private static let rule = "  " + String(repeating: "─", count: 72)
    private static let rows = ["   ❯ 1. Yes, and use auto mode", "     2. Yes, manually approve edits", "     3. Tell Claude what to change"]
    private static let hint = "        shift+tab to approve with this feedback"

    private func fixture(_ name: String) -> [String] { PaneQuestionReaderExitRowTests.fixtureLines(name) }

    /// A box as drawn: `titleRows` then the options, then `footerRows`.
    private func box(titleRows: [String], footerRows: [String]) -> [String] {
        [Self.rule] + titleRows + [""] + Self.rows + [Self.hint, ""] + footerRows
    }

    private let wrappedTitle = ["   Claude has written up a plan and is ready to execute. Would you like", "   to proceed?"]
    private let wideTitle = ["   " + PlanApprovalWrappedTests.title]
    private let wrappedFooter = ["   ctrl+g to edit in Vim ·", "   " + PlanApprovalWrappedTests.path]
    private let wideFooter = ["   ctrl+g to edit in Vim · " + PlanApprovalWrappedTests.path]

    // MARK: - The real captures

    @Test func theRealWrappedCapturesReadAsAPlanBoxWithItsPathAndRows() throws {
        for name in ["plan-box-narrow-wrapped", "plan-box-narrow-wrapped-live-agent", "plan-box-narrow-recent-unwrapped"] {
            let read = try #require(PanePermissionReader.prompt(in: fixture(name)), "\(name)")
            #expect(read.kind == .plan, "\(name)")
            #expect(read.title == Self.title, "\(name)")
            #expect(read.planPath == Self.path, "\(name)")
            #expect(read.options.map(\.label) == ["Yes, and use auto mode", "Yes, manually approve edits", "Tell Claude what to change"], "\(name)")
            #expect(read.options.map(\.index) == [1, 2, 3], "\(name)")
            #expect(read.cursorIndex == 1, "\(name)")
        }
    }

    @Test func aWideDrawingOfTheSameBoxReadsIdenticallyToTheWrappedOne() throws {
        let wrapped = try #require(PanePermissionReader.prompt(in: box(titleRows: wrappedTitle, footerRows: wrappedFooter)))
        let wide = try #require(PanePermissionReader.prompt(in: box(titleRows: wideTitle, footerRows: wideFooter)))
        #expect(wrapped == wide)
        #expect(wrapped.identity == wide.identity)
        #expect(try #require(PanePermissionReader.prompt(in: fixture("plan-box-narrow-wrapped"))) == wide)
    }

    @Test func everyMixOfWrappedAndWideTitleAndFooterReadsTheSame() throws {
        let reference = try #require(PanePermissionReader.prompt(in: box(titleRows: wideTitle, footerRows: wideFooter)))
        for titleRows in [wideTitle, wrappedTitle] {
            for footerRows in [wideFooter, wrappedFooter] {
                #expect(PanePermissionReader.prompt(in: box(titleRows: titleRows, footerRows: footerRows)) == reference)
            }
        }
    }

    // MARK: - Other wraps

    @Test func aTitleWrappedOverThreeRowsIsJoinedWithSingleSpaces() throws {
        let titleRows = ["   Claude has written up a plan and is ready", "   to execute. Would you like", "   to proceed?"]
        let read = try #require(PanePermissionReader.prompt(in: box(titleRows: titleRows, footerRows: wideFooter)))
        #expect(read.title == Self.title)
        #expect(read.kind == .plan)
    }

    @Test func aTitleWrappedOverFourRowsIsNotRecognised() {
        let titleRows = ["   Claude has written up a plan", "   and is ready to execute.", "   Would you like", "   to proceed?"]
        #expect(PanePermissionReader.prompt(in: box(titleRows: titleRows, footerRows: wideFooter)) == nil)
    }

    /// The dashboard only continues a footer whose row ends at the "·" (`PLAN_PATH_FOOTER_PREFIX_RE`); a path
    /// already begun on the footer row that wraps has no `.md` on it, so Python reads no path. Swift follows.
    @Test func aPathBegunOnTheFooterRowAndSplitMidTokenHasNoPathLikeTheDashboard() throws {
        let footerRows = ["   ctrl+g to edit in Vim · ~/.claude/plans/nudge-206c9c93-from-77c13531-66be-4cab", "   -foamy-hopper.md"]
        let read = try #require(PanePermissionReader.prompt(in: box(titleRows: wrappedTitle, footerRows: footerRows)))
        #expect(read.kind == .plan)
        #expect(read.planPath == nil)
    }

    @Test func aPathSplitOverThreeRowsIsJoined() throws {
        let footerRows = ["   ctrl+g to edit in Vim ·", "   ~/.claude/plans/nudge-206c9c93-from-", "   77c13531-66be-4cab-foamy-hopper.md"]
        let read = try #require(PanePermissionReader.prompt(in: box(titleRows: wrappedTitle, footerRows: footerRows)))
        #expect(read.planPath == Self.path)
    }

    @Test func aFooterWhosePathNeverEndsInMdHasNoPathNeverAGuess() throws {
        let footerRows = ["   ctrl+g to edit in Vim ·", "   ~/.claude/plans/notes.txt"]
        let read = try #require(PanePermissionReader.prompt(in: box(titleRows: wrappedTitle, footerRows: footerRows)))
        #expect(read.kind == .plan)
        #expect(read.planPath == nil)
    }

    @Test func aFooterWithNothingAfterItHasNoPath() throws {
        let read = try #require(PanePermissionReader.prompt(in: box(titleRows: wrappedTitle, footerRows: ["   ctrl+g to edit in Vim ·"])))
        #expect(read.planPath == nil)
    }

    @Test func aFooterFollowedByProseIsNotJoinedIntoAPath() throws {
        let footerRows = ["   ctrl+g to edit in Vim ·", "   some trailing words.md"]
        let read = try #require(PanePermissionReader.prompt(in: box(titleRows: wrappedTitle, footerRows: footerRows)))
        #expect(read.planPath == nil)
    }

    @Test func aWrappedShiftTabHintAddsNoOption() throws {
        var screen = box(titleRows: wrappedTitle, footerRows: wrappedFooter)
        let hint = try #require(screen.firstIndex(of: Self.hint))
        screen.replaceSubrange(hint...hint, with: ["        shift+tab to approve with", "        this feedback"])
        let read = try #require(PanePermissionReader.prompt(in: screen))
        #expect(read.options.count == 3)
    }

    // MARK: - Lookalikes stay nil

    @Test func aDifferentSentenceOverTwoRowsIsNeverGuessedAsAPlanBox() {
        let titleRows = ["   Claude has written up a plan and is ready to execute. Would you", "   like to continue?"]
        #expect(PanePermissionReader.prompt(in: box(titleRows: titleRows, footerRows: wrappedFooter)) == nil)
    }

    @Test func theTitleWithExtraTextOnAnotherRowIsNotAPlanBox() {
        let titleRows = ["   Claude has written up a plan and is ready to execute. Would you like", "   to proceed? Really sure?"]
        #expect(PanePermissionReader.prompt(in: box(titleRows: titleRows, footerRows: wrappedFooter)) == nil)
    }

    /// `_join_wrapped_lines` joins physical rows without looking at blank ones, so the dashboard reads a title
    /// split by a blank row as the title; Swift follows (the echoed title is the same joined sentence).
    @Test func aBlankRowBetweenTheTitleHalvesIsJoinedLikeTheDashboardDoes() throws {
        let titleRows = ["   Claude has written up a plan and is ready to execute. Would you like", "", "   to proceed?"]
        let read = try #require(PanePermissionReader.prompt(in: box(titleRows: titleRows, footerRows: wrappedFooter)))
        #expect(read.title == Self.title)
    }

    @Test func aWrappedTitleNextToAReviewScreenIsNotAPlanBox() {
        var screen = box(titleRows: wrappedTitle, footerRows: wrappedFooter)
        screen.insert("   Review your answers", at: 2)
        #expect(PanePermissionReader.prompt(in: screen) == nil)
    }

    @Test func aWrappedPlanBoxIsNeverAQuestionPickerOrAToolBox() {
        let screen = fixture("plan-box-narrow-wrapped")
        #expect(PaneQuestionReader.question(in: screen) == nil)
        #expect(PaneQuestionReader.identity(in: screen) == nil)
        #expect(PanePermissionReader.toolPrompt(in: screen) == nil)
    }

    // MARK: - Where the read is used

    @MainActor @Test func theProbeGivesAWrappedPlanBoxItsReviewButton() async throws {
        let defaults = makeScratchDefaults("wrapped-plan-probe")
        let model = AgentPanelModel(
            store: FrecencyStore(defaults: defaults), triageStore: TriageStore(defaults: defaults),
            blockerProbe: BlockerProbe(retryDelays: [2, 5], pause: { _ in await Task.yield() }), now: { AgentListFixtures.now }
        )
        let source = WrappedPlanScreenSource(screen: .screen(lines: fixture("plan-box-narrow-wrapped"), readAt: AgentListFixtures.now))
        model.statusSource = source
        model.receive(AgentListFixtures.snapshot([AnswerFixtures.blockedAgent("a", blocker: .permission)]))
        func buttons() -> [RowButton] { model.presentation.agents.first { $0.id == "a" }.map(RowButtons.usableButtons) ?? [] }
        #expect(buttons() == [.openTerminal, .peek, .park])
        await waitUntil { buttons() == [.review, .park] }
        #expect(buttons() == [.review, .peek, .park])
        let blocker = try #require(model.presentation.agents.first?.blocker?.permissionPrompt)
        #expect(blocker.isPlan)
        #expect(blocker.planPath == Self.path)
    }
}

/// Serves one screen for every pane read.
private final class WrappedPlanScreenSource: AgentStatusSource, @unchecked Sendable {
    let updates = AsyncStream<StatusSnapshot> { _ in }
    private let screen: PaneScreenResult

    init(screen: PaneScreenResult) { self.screen = screen }

    func paneScreen(paneId: String) async -> PaneScreenResult { screen }
    func focus(paneId: String) async -> FocusResult { .success }
    func answer(paneId: String, choice: AnswerChoice, question: QuestionIdentity) async -> AnswerResult { .failed("unused") }
    func perform(_ kind: SessionActionKind, rowId: String, confirmed: Bool) async -> SessionActionOutcome { .failed("unused") }
}
