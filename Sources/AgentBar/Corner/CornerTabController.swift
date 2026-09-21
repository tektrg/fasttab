import AppKit
import Combine

/// Drives the corner tab: feeds `CornerTabMachine` its events (arrivals, the pointer, panel
/// visibility, the setting, deadlines) and carries out its effects on the tab window and the
/// main panel. Thin glue; the rules live in the machine.
///
/// The pointer is followed by a global mouse-moved monitor (no Accessibility permission needed;
/// it sees moves over other apps), which is how a rest in the bottom-right corner is noticed
/// while nothing is showing. While the tab is up the pointer is polled instead, since moves
/// over AgentBar's own window are not reported to a global monitor. Neither steals focus.
///
/// When the machine calls for a card (`showCard`/`updateCard`), this opens the *same* `answer`/
/// `permission` card the main panel uses (`model`, shared with it) so every existing rule (form
/// batches, plan feedback, the pre-send pane read, footer notices…) applies unchanged; the corner
/// window just hosts it in a different place. Closed the same way it was opened: `closeCardIfNeeded`
/// undoes exactly what `openCard` did, once per continuous showing.
@MainActor
final class CornerTabController {
    struct PanelAccess {
        /// Shows the panel through the same path as the hotkey.
        var open: () -> Void
        /// What the tab says when the pointer rests in the corner.
        var summary: () -> CornerTabContent
    }

    /// The card's footer gear (set by the host in its own wiring, like `AgentPanelController.onOpenSettings`).
    var onOpenSettings: () -> Void = {}

    private static let mousePollSeconds: TimeInterval = 0.05

    private var machine: CornerTabMachine
    private var blockedEpisodes = BlockedEpisodeTracker()
    private let panel: PanelAccess
    private let model: AgentPanelModel
    private let activation: TextInputActivation
    private let clock: () -> Date
    private var window: CornerTabWindowController!
    private var deadlineTask: Task<Void, Never>?
    private var mouseTimer: Timer?
    private var cornerMonitor: Any?
    private var lastMouseSample: Bool?
    /// The agent whose card the corner currently has open (nil while showing the plain pill),
    /// so the activation session and the model's card are torn down exactly once when it ends.
    private var cardOpenAgentID: String?
    private var cardFocusObservers: [NSObjectProtocol] = []
    private var cardChanges: AnyCancellable?

    init(
        isEnabled: Bool, panel: PanelAccess, model: AgentPanelModel, activation: TextInputActivation,
        clock: @escaping () -> Date = { Date() }
    ) {
        machine = CornerTabMachine(isEnabled: isEnabled)
        self.panel = panel
        self.model = model
        self.activation = activation
        self.clock = clock
        window = CornerTabWindowController(
            model: model,
            onClick: { [weak self] in self?.send(.tabClicked, isPanelOpening: true) },
            onDismiss: { [weak self] in self.map { $0.send(.dismissed(cardAgentID: $0.cardOpenAgentID)) } },
            onOpenSettings: { [weak self] in self?.onOpenSettings() }
        )
        cardChanges = model.objectWillChange.sink { [weak self] _ in
            // After the change lands (`objectWillChange` fires before it): a sent or cancelled card leaves the corner empty.
            DispatchQueue.main.async { self?.showPillIfCardEmpty() }
        }
        syncObservers()
    }

    func arrived(_ content: CornerTabContent) { send(.arrival(content)) }

    /// Every reading of Needs you (nil = feed down): keeps the tab sticky while an agent is blocked on the user.
    func needsYouChanged(_ needsYou: [AgentSnapshot]?) {
        let hasNewBlocker = blockedEpisodes.observe(needsYou)
        send(.needsYouChanged(.summary(of: needsYou), hasNewBlocker: hasNewBlocker))
        showPillIfCardEmpty()
    }
    func setEnabled(_ isEnabled: Bool) { send(.enabled(isEnabled)) }
    func panelVisibilityChanged(_ isVisible: Bool) { send(.panelVisibility(isVisible), isPanelOpening: isVisible) }

    private func send(_ event: CornerTabEvent, isPanelOpening: Bool = false) {
        let effects = machine.handle(event, now: clock())
        effects.forEach { perform($0, isPanelOpening: isPanelOpening) }
        syncObservers()
    }

    private func perform(_ effect: CornerTabEffect, isPanelOpening: Bool) {
        switch effect {
        case .showTab(let content):
            closeCardIfNeeded()
            window.show(content)
        case .showSummaryTab:
            showSummary()
        case .updateTab(let content):
            closeCardIfNeeded()
            window.update(content)
        case .showCard(let agentID):
            if openCard(agentID) {
                window.showCard()
            } else {
                window.show(panel.summary())
            }
        case .updateCard(let agentID):
            if openCard(agentID) {
                window.updateCard()
            } else {
                window.update(panel.summary())
            }
        case .slideTabOut:
            leaveCard(isPanelOpening: isPanelOpening)
            window.slideOut()
        case .removeTabNow:
            leaveCard(isPanelOpening: isPanelOpening)
            window.removeNow()
        case .openPanel:
            panel.open()
        }
    }

    /// The pointer rested in the corner: the summary can itself name a sole cardable agent
    /// (one already blocked before the machine ever announced it, e.g. at launch).
    private func showSummary() {
        let summary = panel.summary()
        if let agentID = summary.soleCardableAgentID, openCard(agentID) {
            window.showCard()
        } else {
            closeCardIfNeeded()
            window.show(summary)
        }
    }

    // MARK: - The corner-hosted card

    /// Opens (or keeps open) `agentID`'s card on the shared model, and starts the same
    /// dictation-activation session the main panel uses, once per continuous card showing.
    /// False when there is no card to show (the caller shows the pill instead).
    private func openCard(_ agentID: String) -> Bool {
        guard model.openCardForCorner(agentID: agentID) else {
            closeCardIfNeeded()
            return false
        }
        let isFreshOpen = cardOpenAgentID == nil
        cardOpenAgentID = agentID
        guard isFreshOpen else { return true }
        activation.panelDidShow()
        startCardFocusObservers()
        return true
    }

    /// The card window is up but its card is gone (sent, cancelled, or the blocker changed kind): it
    /// shows the agent's new card if there is one, else the pill, rather than a header and footer
    /// around nothing.
    private func showPillIfCardEmpty() {
        guard let agentID = cardOpenAgentID, !model.answer.isOpen, !model.permission.isOpen else { return }
        if model.openCardForCorner(agentID: agentID) { return }
        closeCardIfNeeded()
        window.update(panel.summary())
    }

    /// The tab or card is going away. When the main panel is what is opening, its own `resetForShow`
    /// has already closed the card (the panel starts clean) and it owns the activation session now,
    /// so only the corner's bookkeeping is dropped.
    private func leaveCard(isPanelOpening: Bool) {
        guard isPanelOpening else { return closeCardIfNeeded() }
        guard cardOpenAgentID != nil else { return }
        cardOpenAgentID = nil
        stopCardFocusObservers()
    }

    private func closeCardIfNeeded() {
        guard cardOpenAgentID != nil else { return }
        cardOpenAgentID = nil
        model.closeCardOpenedForCorner()
        stopCardFocusObservers()
        activation.panelDidHide()
    }

    /// Mirrors `AgentPanelController.startFocusObservers`: while the corner's card is up, a text
    /// field appearing in it (typed "Other"/feedback) activates AgentBar for dictation, and the
    /// user switching to another app on purpose lets go of that activation.
    private func startCardFocusObservers() {
        guard cardFocusObservers.isEmpty else { return }
        let center = NotificationCenter.default
        let appeared = center.addObserver(forName: AnswerTextView.didAppearNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.activation.textInputAppeared() }
        }
        let resign = center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.activation.appResignedActive() }
        }
        cardFocusObservers = [appeared, resign]
    }

    private func stopCardFocusObservers() {
        cardFocusObservers.forEach(NotificationCenter.default.removeObserver)
        cardFocusObservers = []
    }

    // MARK: - What the machine wants watched

    private func syncObservers() {
        scheduleDeadline()
        machine.wantsCornerWatch ? startCornerMonitor() : stopCornerMonitor()
        machine.wantsMousePolling ? startMousePolling() : stopMousePolling()
    }

    private func scheduleDeadline() {
        deadlineTask?.cancel()
        guard let deadline = machine.nextDeadline else { return }
        let delay = max(0, deadline.timeIntervalSince(clock()))
        deadlineTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.deadlineFired()
        }
    }

    /// The pointer may have left since the last move the monitor saw (a rest sends no moves).
    private func deadlineFired() {
        sampleMouse()
        send(.deadlineReached)
    }

    private func startCornerMonitor() {
        guard cornerMonitor == nil else { return }
        cornerMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleMouse() }
        }
    }

    private func stopCornerMonitor() {
        guard let cornerMonitor else { return }
        NSEvent.removeMonitor(cornerMonitor)
        self.cornerMonitor = nil
        lastMouseSample = nil
    }

    private func startMousePolling() {
        guard mouseTimer == nil else { return }
        mouseTimer = Timer.scheduledTimer(withTimeInterval: Self.mousePollSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleMouse() }
        }
        sampleMouse()
    }

    private func stopMousePolling() {
        mouseTimer?.invalidate()
        mouseTimer = nil
    }

    /// Only changes are sent; the machine cares about entering and leaving. The corner counts only
    /// with no mouse button down (a drag passing through it is not a hover); the tab always counts.
    private func sampleMouse() {
        let location = NSEvent.mouseLocation
        let overTab = window.frame?.contains(location) == true
        let inCorner = NSEvent.pressedMouseButtons == 0
            && CornerHotZone.contains(location, displayFrames: NSScreen.screens.map(\.frame))
        let isOver = overTab || inCorner
        guard isOver != lastMouseSample else { return }
        lastMouseSample = isOver
        send(.mouse(isOverCornerOrTab: isOver))
    }
}
