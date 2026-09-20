import Foundation
import Testing
@testable import AgentBar

/// QA pass 2: focus hand-back edge cases found by review (see `TextInputActivation`).
@MainActor
struct QAPass2FocusTests {
    private let focus = FakeAppFocus()

    private func makeActivation() -> TextInputActivation {
        TextInputActivation(focus: focus, isEnabled: { true }, isShortcutModifierHeld: { false }, sleep: { _ in })
    }

    /// An agent switch hides the panel without restoring (the dashboard raises the terminal itself). When the
    /// switch FAILS the panel comes back; AgentBar is still the frontmost app, so closing it must hand the front
    /// back to the app the user came from instead of leaving them typing into a windowless app.
    @Test func aFailedAgentSwitchDoesNotStrandFocusInAgentBar() {
        let activation = makeActivation()
        activation.panelDidShow()
        activation.textInputAppeared()                             // a card text box took the front (previous app 200)
        activation.panelDidHide(restoringFocus: false, handingOffToAgentSwitch: true)
        activation.panelDidShow()                                  // the switch failed: panel is back, AgentBar still frontmost
        activation.panelDidHide()                                  // Esc
        #expect(focus.activatedProcessIDs == [200])
    }

    @Test func aSuccessfulAgentSwitchNeverRestoresOverTheAgentsTerminal() {
        let activation = makeActivation()
        activation.panelDidShow()
        activation.textInputAppeared()
        activation.panelDidHide(restoringFocus: false, handingOffToAgentSwitch: true)
        focus.frontmostProcessID = 300                             // the dashboard raised the agent's terminal
        activation.panelDidShow()
        activation.panelDidHide()
        #expect(focus.activatedProcessIDs.isEmpty)
    }

    @Test func aSettingsHideIsNotAHandOffBackToAnOldApp() {
        let activation = makeActivation()
        activation.panelDidShow()
        activation.textInputAppeared()
        activation.panelDidHide(restoringFocus: false)             // Settings took the front, and stays
        activation.panelDidShow()
        activation.panelDidHide()
        #expect(focus.activatedProcessIDs.isEmpty)
    }
}
