import AppKit

/// Makes AgentBar the frontmost app only while a card text box is on screen, so
/// dictation tools (Wispr Flow, Superwhisper, macOS Dictation), which type into
/// the frontmost app, reach it. The plain ⌥Tab list and the search box stay
/// non-activating. When the panel hides, focus goes back to the app the user
/// came from, unless they have already moved on.
///
/// Fed by: `textInputAppeared` (from `AnswerTextView`), `panelDidShow` /
/// `panelDidHide`, and `appResignedActive` (the user switched to another app
/// on purpose). Every summon starts with no card open (`resetForShow`), so a
/// text box can only appear after `panelDidShow`; one appearing while the
/// panel is hidden is a stale view and ignored.
@MainActor
final class TextInputActivation {
    /// Hidden opt-out: `defaults write com.trungluong.AgentBar activatesForTextInput -bool NO`.
    static let enabledDefaultsKey = "activatesForTextInput"
    static let heldPollInterval: Duration = .milliseconds(50)

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledDefaultsKey) as? Bool ?? true
    }

    private let focus: AppFocusing
    private let isEnabled: () -> Bool
    private let isShortcutModifierHeld: () -> Bool
    private let sleep: (Duration) async -> Void

    private var isPanelShown = false
    private var previousProcessID: pid_t?
    /// The app to go back to if an agent switch that hid the panel fails and the panel returns while
    /// AgentBar still has the front (`panelDidHide(handingOffToAgentSwitch:)`).
    private var previousProcessIDAfterSwitchHandOff: pid_t?
    private var waitTask: Task<Void, Never>?

    /// True from the moment AgentBar took the front until the panel hides or the user leaves.
    private(set) var isActive = false

    init(
        focus: AppFocusing,
        isEnabled: @escaping () -> Bool = { TextInputActivation.isEnabled() },
        isShortcutModifierHeld: @escaping () -> Bool,
        sleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.focus = focus
        self.isEnabled = isEnabled
        self.isShortcutModifierHeld = isShortcutModifierHeld
        self.sleep = sleep
    }

    func textInputAppeared() {
        guard isPanelShown, !isActive, waitTask == nil, isEnabled() else { return }
        activateWhenShortcutModifierReleased()
    }

    func panelDidShow() {
        isPanelShown = true
        adoptSwitchHandOffIfAgentBarStillHasTheFront()
    }

    /// Ends the session. `restoringFocus: false` when the caller is about to
    /// bring another window to the front itself (Settings, an agent switch).
    /// `handingOffToAgentSwitch`: the hide is for a switch whose terminal is about to be raised; if the switch
    /// fails and the panel comes back with AgentBar still frontmost, the same previous app is used again.
    func panelDidHide(restoringFocus: Bool = true, handingOffToAgentSwitch: Bool = false) {
        waitTask?.cancel()
        waitTask = nil
        isPanelShown = false
        let previous = previousProcessID
        let shouldRestore = isActive && restoringFocus
        previousProcessIDAfterSwitchHandOff = handingOffToAgentSwitch && isActive ? previous : nil
        isActive = false
        previousProcessID = nil
        // Only while AgentBar still has the front: if the user already picked another app, leave it alone.
        guard shouldRestore, let previous, focus.frontmostProcessID == focus.ownProcessID else { return }
        focus.activate(processID: previous)
    }

    /// A panel that returns after a failed agent switch finds AgentBar still frontmost and nobody to give the
    /// front back to: adopt the app remembered from before the switch. Anything else (the switch worked and
    /// the terminal has the front) forgets it.
    private func adoptSwitchHandOffIfAgentBarStillHasTheFront() {
        defer { previousProcessIDAfterSwitchHandOff = nil }
        guard let previous = previousProcessIDAfterSwitchHandOff, !isActive,
              focus.frontmostProcessID == focus.ownProcessID else { return }
        previousProcessID = previous
        isActive = true
    }

    /// AgentBar lost the front (user clicked or switched to another app): that
    /// app is where they want to be, so nothing is restored afterwards.
    func appResignedActive() {
        isActive = false
        previousProcessID = nil
    }

    /// Test seam: waits for a deferred (⌥ still held) activation to settle.
    func waitForPendingActivation() async {
        await waitTask?.value
    }

    // MARK: - Activation

    private func activateWhenShortcutModifierReleased() {
        guard isShortcutModifierHeld() else {
            activate()
            return
        }
        // Mid ⌥-hold: leave the switcher alone until the modifier is released.
        waitTask = Task { [weak self] in
            while let self, self.isShortcutModifierHeld(), !Task.isCancelled {
                await self.sleep(Self.heldPollInterval)
            }
            guard let self, !Task.isCancelled else { return }
            self.waitTask = nil
            self.textInputAppeared()
        }
    }

    private func activate() {
        let front = focus.frontmostProcessID
        previousProcessID = front == focus.ownProcessID ? nil : front
        isActive = true
        focus.activateSelf()
    }
}
