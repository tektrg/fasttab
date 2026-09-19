import Testing
@testable import AgentBar

struct PermissionCardStateTests {
    typealias P = PermissionFixtures

    private func ready(_ prompt: PermissionPrompt = P.bash) -> PermissionCardState {
        var state = PermissionCardState(prompt: prompt)
        state.resolve(live: prompt, failure: nil)
        return state
    }

    private func press(_ state: inout PermissionCardState, _ key: PermissionCardState.Key) -> PermissionCardState.Effect {
        state.handle(key)
    }

    // MARK: - Nothing is decided before the pane has been read

    @Test func nothingCanBeDecidedWhileTheTerminalIsBeingChecked() {
        var state = PermissionCardState(prompt: P.bash)
        #expect(state.phase == .checking)
        #expect(state.choices.isEmpty)
        for key: PermissionCardState.Key in [.down, .up, .digit(1), .enter, .send, .other] {
            #expect(press(&state, key) == .none)
        }
        #expect(state.highlighted == nil)
        #expect(!state.canSend)
    }

    @Test func escapeAlwaysGetsBackToTheList() {
        var checking = PermissionCardState(prompt: P.bash)
        #expect(press(&checking, .escape) == .close)
        var unavailable = PermissionCardState(prompt: P.bash)
        unavailable.resolve(live: nil, failure: "gone")
        #expect(press(&unavailable, .escape) == .close)
    }

    @Test func aBoxThatCannotBeReadIsUnavailableWithTheReasonAndNeverSends() {
        var state = PermissionCardState(prompt: P.bash)
        state.resolve(live: nil, failure: "pane not found")
        #expect(state.phase == .unavailable("pane not found"))
        #expect(press(&state, .digit(1)) == .none)
        #expect(press(&state, .enter) == .none)
        #expect(state.hintMode == .unavailable)
    }

    @Test func theBoxTheDashboardWillCompareIsTheOneReadFromThePane() {
        var state = PermissionCardState(prompt: P.oneOff)
        state.resolve(live: P.bash, failure: nil)
        #expect(state.prompt == P.bash)
        #expect(state.changedNote == PermissionCardState.changedNoteText)
        #expect(state.phase == .ready)
    }

    @Test func aPaneReadingOfTheSameBoxKeepsNoNote() {
        var state = PermissionCardState(prompt: P.bash)
        state.resolve(live: P.bash, failure: nil)
        #expect(state.changedNote == nil)
    }

    @Test func aLateSecondReadingNeverChangesWhatIsShown() {
        var state = ready()
        state.resolve(live: P.oneOff, failure: nil)
        #expect(state.prompt == P.bash)
    }

    // MARK: - No default choice

    @Test func nothingIsHighlightedAtFirstAndEnterDoesNothing() {
        var state = ready()
        #expect(state.highlighted == nil)
        #expect(press(&state, .enter) == .none)
        #expect(press(&state, .send) == .none)
        #expect(state.actionTitle == "Choose an option")
        #expect(!state.canSend)
    }

    @Test func downFromNothingLandsOnTheFirstChoiceAndUpOnTheLast() {
        var down = ready()
        _ = press(&down, .down)
        #expect(down.highlighted == .allow)
        var up = ready()
        _ = press(&up, .up)
        #expect(up.highlighted == .deny)
    }

    @Test func arrowsStayInsideTheChoicesTheBoxHas() {
        var state = ready(P.oneOff)
        _ = press(&state, .down)
        _ = press(&state, .down)
        _ = press(&state, .down)
        #expect(state.highlighted == .deny)
        _ = press(&state, .up)
        _ = press(&state, .up)
        #expect(state.highlighted == .allow)
    }

    @Test func aDigitOnlyHighlightsTheOptionWithThatNumberAndNeverSends() {
        var state = ready()
        #expect(press(&state, .digit(3)) == .none)
        #expect(state.highlighted == .deny)
        #expect(press(&state, .digit(1)) == .none)
        #expect(state.highlighted == .allow)
        #expect(press(&state, .digit(9)) == .none)   // not a visible option: nothing changes
        #expect(state.highlighted == .allow)
    }

    // MARK: - Sending

    @Test func enterSendsTheHighlightedAllowInOnePress() {
        var state = ready()
        _ = press(&state, .digit(1))
        #expect(press(&state, .enter) == .send(.allow))
    }

    @Test func denyIsOnePress() {
        var state = ready()
        _ = press(&state, .digit(3))
        #expect(press(&state, .enter) == .send(.deny))
    }

    @Test func theActionButtonSendsTheHighlightedChoiceAndSaysWhich() {
        var state = ready()
        _ = press(&state, .digit(3))
        #expect(state.actionTitle == "Deny")
        #expect(press(&state, .send) == .send(.deny))
    }

    @Test func aClickHighlightsAndNeverSends() {
        var state = ready()
        state.clickChoice(.deny)
        #expect(state.highlighted == .deny)
        var oneOff = ready(P.oneOff)
        oneOff.clickChoice(.allowAlways)   // not offered on this box
        #expect(oneOff.highlighted == nil)
    }

    // MARK: - Allow always needs a second, deliberate press

    @Test func allowAlwaysAsksForConfirmationFirst() {
        var state = ready()
        _ = press(&state, .digit(2))
        #expect(press(&state, .enter) == .none)
        #expect(state.isConfirmingAlways)
        #expect(state.actionTitle == "Confirm always allow")
        #expect(state.highlightedOptionLabel == "Yes, and don't ask again for rm commands in /tmp")
        #expect(state.hintMode == .confirmingAlways)
        #expect(press(&state, .enter) == .send(.allowAlways))
    }

    @Test func theActionButtonNeedsTwoPressesForAllowAlwaysToo() {
        var state = ready()
        state.clickChoice(.allowAlways)
        #expect(press(&state, .send) == .none)
        #expect(press(&state, .send) == .send(.allowAlways))
    }

    @Test func anyOtherKeyCancelsThePendingConfirmation() {
        for key: PermissionCardState.Key in [.up, .down, .digit(1), .digit(2), .other] {
            var state = ready()
            _ = press(&state, .digit(2))
            _ = press(&state, .enter)
            #expect(state.isConfirmingAlways)
            _ = press(&state, key)
            #expect(!state.isConfirmingAlways, "\(key)")
            if key == .digit(2) || key == .other {
                #expect(press(&state, .enter) == .none)   // asks again rather than sending
            }
        }
    }

    @Test func aClickCancelsThePendingConfirmation() {
        var state = ready()
        _ = press(&state, .digit(2))
        _ = press(&state, .enter)
        state.clickChoice(.deny)
        #expect(!state.isConfirmingAlways)
        #expect(state.highlighted == .deny)
    }

    @Test func escapeWhileConfirmingCancelsOnlyTheConfirmation() {
        var state = ready()
        _ = press(&state, .digit(2))
        _ = press(&state, .enter)
        #expect(press(&state, .escape) == .none)
        #expect(!state.isConfirmingAlways)
        #expect(state.highlighted == .allowAlways)
        #expect(press(&state, .escape) == .close)
    }

    @Test func aBoxWithoutAllowAlwaysCanNeverEnterTheConfirmation() {
        var state = ready(P.oneOff)
        #expect(press(&state, .digit(2)) == .none)   // 2 is "No" here
        #expect(state.highlighted == .deny)
        #expect(!state.isConfirmingAlways)
    }

    // MARK: - Hints

    @Test func theHintsFollowTheState() {
        var state = ready()
        #expect(state.hintMode == .choosing)
        _ = press(&state, .down)
        #expect(state.hintMode == .chosen)
    }
}
