import AppKit

/// Drives the corner tab: feeds `CornerTabMachine` its events (arrivals, the pointer, panel
/// visibility, the setting, deadlines) and carries out its effects on the tab window and the
/// main panel. Thin glue; the rules live in the machine.
///
/// The pointer is followed by a global mouse-moved monitor (no Accessibility permission needed;
/// it sees moves over other apps), which is how a rest in the bottom-right corner is noticed
/// while nothing is showing. While the tab is up the pointer is polled instead, since moves
/// over AgentBar's own window are not reported to a global monitor. Neither steals focus.
@MainActor
final class CornerTabController {
    struct PanelAccess {
        /// Shows the panel through the same path as the hotkey.
        var open: () -> Void
        /// What the tab says when the pointer rests in the corner.
        var summary: () -> CornerTabContent
    }

    private static let mousePollSeconds: TimeInterval = 0.05

    private var machine: CornerTabMachine
    private var blockedEpisodes = BlockedEpisodeTracker()
    private let panel: PanelAccess
    private let clock: () -> Date
    private var window: CornerTabWindowController!
    private var deadlineTask: Task<Void, Never>?
    private var mouseTimer: Timer?
    private var cornerMonitor: Any?
    private var lastMouseSample: Bool?

    init(isEnabled: Bool, panel: PanelAccess, clock: @escaping () -> Date = { Date() }) {
        machine = CornerTabMachine(isEnabled: isEnabled)
        self.panel = panel
        self.clock = clock
        window = CornerTabWindowController { [weak self] in self?.send(.tabClicked) }
        syncObservers()
    }

    func arrived(_ content: CornerTabContent) { send(.arrival(content)) }

    /// Every reading of Needs you (nil = feed down): keeps the tab sticky while an agent is blocked on the user.
    func needsYouChanged(_ needsYou: [AgentSnapshot]?) {
        let hasNewBlocker = blockedEpisodes.observe(needsYou)
        send(.needsYouChanged(.summary(of: needsYou), hasNewBlocker: hasNewBlocker))
    }
    func setEnabled(_ isEnabled: Bool) { send(.enabled(isEnabled)) }
    func panelVisibilityChanged(_ isVisible: Bool) { send(.panelVisibility(isVisible)) }

    private func send(_ event: CornerTabEvent) {
        let effects = machine.handle(event, now: clock())
        effects.forEach(perform)
        syncObservers()
    }

    private func perform(_ effect: CornerTabEffect) {
        switch effect {
        case .showTab(let content): window.show(content)
        case .showSummaryTab: window.show(panel.summary())
        case .updateTab(let content): window.update(content)
        case .slideTabOut: window.slideOut()
        case .removeTabNow: window.removeNow()
        case .openPanel: panel.open()
        }
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
