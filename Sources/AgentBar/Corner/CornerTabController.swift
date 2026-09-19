import AppKit

/// Drives the corner tab: feeds `CornerTabMachine` its events (arrivals, mouse,
/// keys, panel visibility, the setting, deadlines) and carries out its effects
/// on the tab window and the main panel. Thin glue; the rules live in the machine.
///
/// The mouse is polled (only while a tab or a hover-opened panel is up) rather
/// than tracked per window: one rule, "over the tab or the panel", for both.
@MainActor
final class CornerTabController {
    struct PanelAccess {
        /// Shows the panel through the same path as the hotkey.
        var open: () -> Void
        var close: () -> Void
        /// The panel's frame while visible.
        var visibleFrame: () -> CGRect?
    }

    private static let mousePollSeconds: TimeInterval = 0.05

    private var machine: CornerTabMachine
    private let panel: PanelAccess
    private let clock: () -> Date
    private var window: CornerTabWindowController!
    private var deadlineTask: Task<Void, Never>?
    private var mouseTimer: Timer?
    private var lastMouseSample: Bool?
    private var keyMonitor: Any?

    init(isEnabled: Bool, panel: PanelAccess, clock: @escaping () -> Date = { Date() }) {
        machine = CornerTabMachine(isEnabled: isEnabled)
        self.panel = panel
        self.clock = clock
        window = CornerTabWindowController { [weak self] in self?.send(.tabClicked) }
    }

    func arrived(_ content: CornerTabContent) { send(.arrival(content)) }
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
        case .updateTab(let content): window.update(content)
        case .slideTabOut: window.slideOut()
        case .removeTabNow: window.removeNow()
        case .openPanel: panel.open()
        case .closePanel: panel.close()
        }
    }

    // MARK: - What the machine wants watched

    private func syncObservers() {
        scheduleDeadline()
        machine.wantsMouseUpdates ? startMousePolling() : stopMousePolling()
        machine.wantsKeyPresses ? startKeyMonitor() : stopKeyMonitor()
    }

    private func scheduleDeadline() {
        deadlineTask?.cancel()
        guard let deadline = machine.nextDeadline else { return }
        let delay = max(0, deadline.timeIntervalSince(clock()))
        deadlineTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.send(.deadlineReached)
        }
    }

    private func startMousePolling() {
        guard mouseTimer == nil else { return }
        lastMouseSample = nil
        mouseTimer = Timer.scheduledTimer(withTimeInterval: Self.mousePollSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleMouse() }
        }
        sampleMouse()
    }

    private func stopMousePolling() {
        mouseTimer?.invalidate()
        mouseTimer = nil
    }

    /// Only changes are sent; the machine cares about entering and leaving.
    private func sampleMouse() {
        let location = NSEvent.mouseLocation
        let isOver = [window.frame, panel.visibleFrame()].contains { $0?.contains(location) == true }
        guard isOver != lastMouseSample else { return }
        lastMouseSample = isOver
        send(.mouse(isOverTabOrPanel: isOver))
    }

    private func startKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.send(.keyPressed) }
            return event
        }
    }

    private func stopKeyMonitor() {
        guard let keyMonitor else { return }
        NSEvent.removeMonitor(keyMonitor)
        self.keyMonitor = nil
    }
}
