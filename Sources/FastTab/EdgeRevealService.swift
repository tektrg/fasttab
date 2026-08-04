import AppKit
import Combine

/// Drives the notch/edge hover-reveal trigger. Entering the trigger zone opens
/// the command bar after a short dwell (`dwellDelay`) — long enough that a
/// cursor merely passing through on its way to the menu bar or a screen edge
/// doesn't open it, short enough to still feel like hover rather than a
/// hold-to-confirm gesture. `CommandBarPanelController.playRevealAnimation`
/// supplies the "grows out of the edge" motion that sells the connection
/// between cursor and bar.
@MainActor
final class EdgeRevealService: NSObject {
    static let shared = EdgeRevealService()

    /// Outward margin on the hit-test rect so the pointer doesn't need to
    /// land pixel-perfect on the (often only 10pt-wide) zone boundary.
    private static let hitTestOutset: CGFloat = 4

    /// How long the cursor must stay in the zone before the bar opens.
    private static let dwellDelay: TimeInterval = 0.28

    private var mouseMovedMonitor: Any?
    /// `addGlobalMonitorForEvents` only delivers events posted to *other*
    /// applications — while one of FastTab's own windows (e.g. Settings) is
    /// frontmost, mouse moves are routed to FastTab itself and the global
    /// monitor goes silent. This local monitor covers that case so hovering
    /// the trigger zone still works while Settings is open.
    private var localMouseMovedMonitor: Any?
    /// Tracks zone membership so triggering happens on the transition into
    /// the zone, not merely while inside it — otherwise dismissing the bar
    /// (e.g. via Escape) while the cursor is still sitting in the zone would
    /// reopen it on the very next mouse tick.
    private var wasInsideZone = false
    /// Non-nil while a dwell is in flight; cancelled if the cursor leaves the
    /// zone before `dwellDelay` elapses.
    private var pendingReveal: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()

    private override init() {
        super.init()
    }

    /// Call once at app launch. Reacts to Settings changes for the rest of
    /// the app's lifetime — no separate start/stop call needed elsewhere.
    func start() {
        EdgeRevealStore.shared.$style
            .sink { [weak self] style in
                self?.apply(style: style)
            }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    private func apply(style: EdgeRevealStyle) {
        cancelPendingReveal()
        wasInsideZone = false
        if style == .off {
            stopMonitoring()
        } else {
            startMonitoring()
        }
    }

    @objc private func handleScreenParametersChanged() {
        // Display connect/disconnect and lid open/close can move or remove
        // the notch/edge entirely — the next mouse move recomputes the zone
        // fresh, but drop the stale membership flag so a zone that's now in
        // a different spot doesn't look like it was already entered.
        cancelPendingReveal()
        wasInsideZone = false
    }

    // MARK: - Monitor lifecycle

    private func startMonitoring() {
        if mouseMovedMonitor == nil {
            mouseMovedMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
                DispatchQueue.main.async {
                    self?.handleMouseMoved(event)
                }
            }
        }

        if localMouseMovedMonitor == nil {
            localMouseMovedMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
                self?.handleMouseMoved(event)
                return event
            }
        }
    }

    private func stopMonitoring() {
        if let monitor = mouseMovedMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMovedMonitor = nil
        }
        if let monitor = localMouseMovedMonitor {
            NSEvent.removeMonitor(monitor)
            localMouseMovedMonitor = nil
        }
        cancelPendingReveal()
        wasInsideZone = false
    }

    private func cancelPendingReveal() {
        pendingReveal?.cancel()
        pendingReveal = nil
    }

    // MARK: - Event handling

    private func handleMouseMoved(_ event: NSEvent) {
        let style = EdgeRevealStore.shared.style
        guard style != .off, let screen = NSScreen.main else { return }

        let info = EdgeRevealGeometry.screenInfo(for: screen)
        guard let zone = EdgeRevealGeometry.triggerZone(for: style, screenInfo: info) else { return }

        let location = NSEvent.mouseLocation
        let insideZone = zone.insetBy(dx: -Self.hitTestOutset, dy: -Self.hitTestOutset).contains(location)

        guard insideZone, !wasInsideZone else {
            // Leaving the zone abandons an in-flight dwell, so a cursor merely
            // passing through never opens the bar.
            if !insideZone { cancelPendingReveal() }
            wasInsideZone = insideZone
            return
        }
        wasInsideZone = true

        guard !AppState.shared.isVisible else { return }

        cancelPendingReveal()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingReveal = nil
            // Re-check on fire: the dwell only proves the cursor didn't leave,
            // and the bar may have been opened another way meanwhile.
            guard self.wasInsideZone, !AppState.shared.isVisible else { return }
            AppState.shared.showCommandBar(revealStyle: style)
        }
        pendingReveal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dwellDelay, execute: work)
    }
}
