import Testing
@testable import AgentBar

struct PlanCardStateTests {
    typealias F = PlanFixtures

    private func ready(_ prompt: PermissionPrompt = F.box) -> PlanCardState {
        var state = PlanCardState(prompt: prompt)
        state.resolve(live: prompt, failure: nil)
        return state
    }

    // MARK: - Nothing before the pane has been read

    @Test func nothingCanBeChosenWhileTheTerminalIsBeingChecked() {
        var state = PlanCardState(prompt: F.box)
        #expect(state.phase == .checking)
        #expect(state.options.isEmpty)
        for key: PlanCardState.Key in [.down, .up, .digit(1), .enter, .send, .other] {
            #expect(state.handle(key) == .none)
        }
        #expect(state.highlightedIndex == nil)
        #expect(!state.canSend)
    }

    @Test func escapeAlwaysGetsBackToTheList() {
        var checking = PlanCardState(prompt: F.box)
        #expect(checking.handle(.escape) == .close)
        var unavailable = PlanCardState(prompt: F.box)
        unavailable.resolve(live: nil, failure: "gone")
        #expect(unavailable.handle(.escape) == .close)
        #expect(unavailable.phase == .unavailable("gone"))
        #expect(unavailable.handle(.enter) == .none)
    }

    @Test func thePanesBoxReplacesTheFeedsAndSaysWhenItDiffered() {
        var state = PlanCardState(prompt: F.box)
        state.resolve(live: F.otherPlan, failure: nil)
        #expect(state.prompt == F.otherPlan)
        #expect(state.changedNote == PermissionCardState.changedNoteText)
        var same = PlanCardState(prompt: F.box)
        same.resolve(live: F.box, failure: nil)
        #expect(same.changedNote == nil)
    }

    // MARK: - Never a default

    @Test func nothingIsChosenToBeginWithNotEvenTheRowTheTerminalsCursorIsOn() {
        let state = ready()
        #expect(state.prompt.cursorIndex == 1)
        #expect(state.highlightedIndex == nil)
        #expect(!state.canSend)
        #expect(state.actionTitle == "Choose an option")
    }

    @Test func returnWithNothingChosenDoesNothing() {
        var state = ready()
        #expect(state.handle(.enter) == .none)
        #expect(state.handle(.send) == .none)
        #expect(!state.isConfirmingPrivilege)
        #expect(!state.isTypingFeedback)
    }

    @Test func digitsAndArrowsOnlyHighlightNeverSend() {
        var state = ready()
        #expect(state.handle(.digit(2)) == .none)
        #expect(state.highlightedIndex == 2)
        #expect(state.handle(.digit(9)) == .none)   // no such row
        #expect(state.highlightedIndex == 2)
        #expect(state.handle(.down) == .none)
        #expect(state.highlightedIndex == 3)
        #expect(state.handle(.down) == .none)
        #expect(state.highlightedIndex == 3)
        #expect(state.handle(.up) == .none)
        #expect(state.highlightedIndex == 2)
    }

    @Test func downFromNothingLandsOnTheFirstRowAndUpOnTheLast() {
        var down = ready()
        _ = down.handle(.down)
        #expect(down.highlightedIndex == 1)
        var up = ready()
        _ = up.handle(.up)
        #expect(up.highlightedIndex == 3)
    }

    // MARK: - The privilege change needs a second press

    @Test func autoModeNeedsASecondPressThatNamesTheChange() {
        var state = ready()
        _ = state.handle(.digit(1))
        #expect(state.handle(.enter) == .none)
        #expect(state.isConfirmingPrivilege)
        #expect(state.confirmText == "This puts the agent in auto mode — press again to confirm")
        #expect(state.hintMode == .confirmingPrivilege)
        #expect(state.handle(.enter) == .send(.init(option: F.box.options[0], feedback: nil)))
    }

    @Test func bypassPermissionsNeedsASecondPressToo() {
        var state = ready(F.bypassBox)
        _ = state.handle(.digit(1))
        #expect(state.handle(.send) == .none)
        #expect(state.isConfirmingPrivilege)
        #expect(state.confirmText?.contains("bypass") == true)
        #expect(state.handle(.send) == .send(.init(option: F.bypassBox.options[0], feedback: nil)))
    }

    @Test func anyOtherKeyCancelsThePendingConfirmation() {
        for cancel: PlanCardState.Key in [.other, .up, .down, .digit(2), .escape] {
            var state = ready()
            _ = state.handle(.digit(1))
            _ = state.handle(.enter)
            #expect(state.isConfirmingPrivilege)
            let effect = state.handle(cancel)
            #expect(effect == .none, "\(cancel)")
            #expect(!state.isConfirmingPrivilege, "\(cancel)")
        }
    }

    @Test func aClickOnAnotherRowCancelsTheConfirmationToo() {
        var state = ready()
        _ = state.handle(.digit(1))
        _ = state.handle(.enter)
        state.clickOption(index: 2)
        #expect(!state.isConfirmingPrivilege)
        #expect(state.highlightedIndex == 2)
    }

    @Test func manualApprovalNeedsNoSecondPress() {
        var state = ready()
        _ = state.handle(.digit(2))
        #expect(state.handle(.enter) == .send(.init(option: F.box.options[1], feedback: nil)))
    }

    @Test func thePrivilegeRuleReadsTheLabelNotThePosition() {
        // Wording that names nothing special gets no second press, whatever row it is on.
        var state = ready(F.unknownWording)
        _ = state.handle(.digit(1))
        #expect(state.handle(.enter) == .send(.init(option: F.unknownWording.options[0], feedback: nil)))
    }

    // MARK: - The feedback row

    @Test func theFeedbackRowIsTheOneSayingTellClaudeOtherwiseTheLastUnlessItSaysYes() {
        #expect(F.box.feedbackOption?.index == 3)
        #expect(F.unknownWording.feedbackOption?.index == 3)
        let onlyYes = PermissionPrompt(
            tool: "ExitPlanMode", detail: "", title: F.title,
            options: [.init(index: 1, label: "Yes, and use auto mode"), .init(index: 2, label: "Yes, manually approve edits")],
            cursorIndex: 1, kind: .plan, planPath: nil
        )
        #expect(onlyYes.feedbackOption == nil)
        #expect(PermissionFixtures.bash.feedbackOption == nil)   // a tool box has none
    }

    @Test func returnOnTheFeedbackRowOpensTheTextBoxAndSendsNothing() {
        var state = ready()
        _ = state.handle(.digit(3))
        #expect(state.handle(.enter) == .none)
        #expect(state.isTypingFeedback)
        #expect(state.hintMode == .typingFeedback)
    }

    @Test func clickingTheFeedbackRowOpensTheTextBoxDirectly() {
        var state = ready()
        state.clickOption(index: 3)
        #expect(state.isTypingFeedback)
        state.clickOption(index: 2)
        #expect(!state.isTypingFeedback)
    }

    @Test func emptyOrBlankFeedbackIsNeverSent() {
        var state = ready()
        state.clickOption(index: 3)
        #expect(!state.canSend)
        #expect(state.handle(.enter) == .none)
        state.feedbackText = "  \n  "
        #expect(!state.canSend)
        #expect(state.handle(.enter) == .none)
        #expect(state.isTypingFeedback)
    }

    @Test func feedbackIsSentWithTheFeedbackRowAndLineBreaksBecomeSpaces() {
        var state = ready()
        state.clickOption(index: 3)
        state.feedbackText = "  Split step 2\n\ninto two   steps  "
        #expect(state.canSend)
        #expect(state.handle(.enter) == .send(.init(option: F.box.options[2], feedback: "Split step 2 into two steps")))
    }

    @Test func feedbackIsCutAtWhatTheDashboardWillType() {
        var state = ready()
        state.clickOption(index: 3)
        state.feedbackText = String(repeating: "x", count: 700)
        #expect(state.handle(.enter) == .send(.init(option: F.box.options[2], feedback: String(repeating: "x", count: 500))))
        #expect(state.isFeedbackTooLong)
    }

    @Test func escapeInTheTextBoxGoesBackToTheRowsAndKeepsTheDraft() {
        var state = ready()
        state.clickOption(index: 3)
        state.feedbackText = "draft"
        #expect(state.handle(.escape) == .none)
        #expect(!state.isTypingFeedback)
        #expect(state.feedbackText == "draft")
        #expect(state.highlightedIndex == 3)
        #expect(state.handle(.escape) == .close)
    }

    @Test func aFeedbackRowNeverSendsWithoutText() {
        var state = ready()
        _ = state.handle(.digit(3))
        #expect(state.handle(.send) == .none)   // opens the box
        #expect(state.handle(.send) == .none)   // still empty
    }

    // MARK: - Titles

    @Test func theActionButtonUsesTheBoxsOwnWords() {
        var state = ready()
        _ = state.handle(.digit(2))
        #expect(state.actionTitle == "Yes, manually approve edits")
        _ = state.handle(.digit(1))
        _ = state.handle(.enter)
        #expect(state.actionTitle == "Confirm: Yes, and use auto mode")
        state.clickOption(index: 3)
        #expect(state.actionTitle == "Send feedback")
    }
}
