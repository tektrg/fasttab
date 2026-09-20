import Foundation
import Testing
@testable import AgentBar

@MainActor
final class FakeAppFocus: AppFocusing {
    let ownProcessID: pid_t = 100
    var frontmostProcessID: pid_t? = 200
    var runningProcessIDs: Set<pid_t> = [200]
    private(set) var selfActivations = 0
    private(set) var activatedProcessIDs: [pid_t] = []

    func activateSelf() {
        selfActivations += 1
        frontmostProcessID = ownProcessID
    }

    func activate(processID: pid_t) -> Bool {
        guard runningProcessIDs.contains(processID) else { return false }
        activatedProcessIDs.append(processID)
        frontmostProcessID = processID
        return true
    }
}

/// Dictation tools type into the frontmost app: AgentBar takes the front only for a card text box,
/// and gives it back when the panel closes.
@MainActor
struct TextInputActivationTests {
    private let focus = FakeAppFocus()

    private func makeActivation(
        enabled: Bool = true,
        held: @escaping () -> Bool = { false },
        sleep: @escaping (Duration) async -> Void = { _ in }
    ) -> TextInputActivation {
        TextInputActivation(focus: focus, isEnabled: { enabled }, isShortcutModifierHeld: held, sleep: sleep)
    }

    @Test func plainListNeverActivates() {
        let activation = makeActivation()
        activation.panelDidShow()
        activation.panelDidHide()
        #expect(focus.selfActivations == 0)
        #expect(focus.activatedProcessIDs.isEmpty)
    }

    @Test func textBoxActivatesOnceEvenIfSeveralAppear() {
        let activation = makeActivation()
        activation.panelDidShow()
        activation.textInputAppeared()
        activation.textInputAppeared()
        #expect(focus.selfActivations == 1)
        #expect(activation.isActive)
    }

    @Test func closeRestoresThePreviousAppWhileAgentBarStillHasTheFront() {
        let activation = makeActivation()
        activation.panelDidShow()
        activation.textInputAppeared()
        activation.panelDidHide()
        #expect(focus.activatedProcessIDs == [200])
        #expect(!activation.isActive)
    }

    @Test func noRestoreAfterTheUserSwitchedToAnotherApp() {
        let activation = makeActivation()
        activation.panelDidShow()
        activation.textInputAppeared()
        focus.frontmostProcessID = 300   // user clicked another app
        activation.appResignedActive()
        activation.panelDidHide()
        #expect(focus.activatedProcessIDs.isEmpty)
    }

    @Test func noRestoreWhenFrontmostIsNoLongerAgentBarEvenWithoutTheResignSignal() {
        let activation = makeActivation()
        activation.panelDidShow()
        activation.textInputAppeared()
        focus.frontmostProcessID = 300
        activation.panelDidHide()
        #expect(focus.activatedProcessIDs.isEmpty)
    }

    @Test func noRestoreWhenThePreviousAppIsGone() {
        let activation = makeActivation()
        activation.panelDidShow()
        activation.textInputAppeared()
        focus.runningProcessIDs = []
        activation.panelDidHide()
        #expect(focus.activatedProcessIDs.isEmpty)
    }

    @Test func noRestoreWithoutAPreviousApp() {
        focus.frontmostProcessID = nil
        let activation = makeActivation()
        activation.panelDidShow()
        activation.textInputAppeared()
        activation.panelDidHide()
        #expect(focus.activatedProcessIDs.isEmpty)
    }

    @Test func noRestoreWhenAgentBarWasAlreadyFrontmost() {
        focus.frontmostProcessID = focus.ownProcessID   // e.g. Settings was open
        let activation = makeActivation()
        activation.panelDidShow()
        activation.textInputAppeared()
        activation.panelDidHide()
        #expect(focus.activatedProcessIDs.isEmpty)
    }

    @Test func callerCanSkipTheRestoreForSettingsOrAnAgentSwitch() {
        let activation = makeActivation()
        activation.panelDidShow()
        activation.textInputAppeared()
        activation.panelDidHide(restoringFocus: false)
        #expect(focus.activatedProcessIDs.isEmpty)
    }

    @Test func doubleCloseRestoresOnce() {
        let activation = makeActivation()
        activation.panelDidShow()
        activation.textInputAppeared()
        activation.panelDidHide()
        activation.panelDidHide()
        #expect(focus.activatedProcessIDs == [200])
    }

    @Test func aTextBoxAppearingWhileThePanelIsHiddenIsIgnored() {
        let activation = makeActivation()
        activation.textInputAppeared()
        #expect(focus.selfActivations == 0)
        activation.panelDidShow()
        activation.panelDidHide()
        activation.textInputAppeared()
        #expect(focus.selfActivations == 0)
    }

    @Test func nextSummonStartsFresh() {
        let activation = makeActivation()
        activation.panelDidShow()
        activation.textInputAppeared()
        activation.panelDidHide()
        focus.frontmostProcessID = 300
        focus.runningProcessIDs.insert(300)
        activation.panelDidShow()
        activation.textInputAppeared()
        activation.panelDidHide()
        #expect(focus.selfActivations == 2)
        #expect(focus.activatedProcessIDs == [200, 300])
    }

    @Test func optOutKeepsAgentBarNonActivating() {
        let activation = makeActivation(enabled: false)
        activation.panelDidShow()
        activation.textInputAppeared()
        activation.panelDidHide()
        #expect(focus.selfActivations == 0)
        #expect(focus.activatedProcessIDs.isEmpty)
    }

    @Test func waitsForTheShortcutModifierToBeReleased() async {
        var held = true
        let activation = makeActivation(held: { held }, sleep: { _ in held = false })
        activation.panelDidShow()
        activation.textInputAppeared()
        #expect(focus.selfActivations == 0)   // mid ⌥-hold: nothing yet
        await activation.waitForPendingActivation()
        #expect(focus.selfActivations == 1)
    }

    @Test func closingWhileTheModifierIsStillHeldNeverActivates() async {
        let activation = makeActivation(held: { true }, sleep: { _ in await Task.yield() })
        activation.panelDidShow()
        activation.textInputAppeared()
        activation.panelDidHide()
        await activation.waitForPendingActivation()
        #expect(focus.selfActivations == 0)
        #expect(focus.activatedProcessIDs.isEmpty)
    }

    @Test func enabledByDefaultAndSwitchableOff() {
        let defaults = UserDefaults(suiteName: "TextInputActivationTests-\(UUID().uuidString)")!
        #expect(TextInputActivation.isEnabled(in: defaults))
        defaults.set(false, forKey: TextInputActivation.enabledDefaultsKey)
        #expect(!TextInputActivation.isEnabled(in: defaults))
    }
}
