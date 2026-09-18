import AppKit
import Combine

/// Drives the notch/edge hover-reveal trigger. Entering the trigger zone opens
/// the command bar after a short dwell (`dwellDelay`) — long enough that a
/// cursor merely passing through on its way to the menu bar or a screen edge
/// doesn't open it, short enough to still feel like hover rather than a
/// hold-to-confirm gesture. `CommandBarPanelController.playRevealAnimation`
/// supplies the "grows out of the edge" motion that sells the connection
/// between cursor and bar.
///
/// Detection is one invisible `EdgeRevealHoverWindow` per connected screen,
/// each sized to that screen's trigger zone. That replaced a permanently
/// running global mouse-moved monitor (plus an app-wide idle-sleep-disable to
/// keep it alive against App Nap) — the window server now does the geometry
/// check and only wakes this service when the cursor actually crosses a zone
/// boundary.
@MainActor
final class EdgeRevealService: NSObject {
    static let shared = EdgeRevealService()

    /// Outward margin baked into each hover window's frame so the pointer
    /// doesn't need to land pixel-perfect on the (often only 10pt-wide) zone
    /// boundary.
    private static let hitTestOutset: CGFloat = 4

    /// How long the cursor must stay in the zone before the bar opens. Kept
    /// short enough that the hover reads as an instant reaction rather than a
    /// hold-to-confirm — under ~150ms the response still lands inside the
    /// window where a UI feels directly caused by the gesture. A cursor merely
    /// crossing the (10pt-wide) zone on its way somewhere else clears it in
    /// well under this, so the pass-through filter still holds.
    private static let dwellDelay: TimeInterval = 0.14

    private var currentStyle: EdgeRevealStyle = .off
    private var hoverWindows: [EdgeRevealHoverWindow] = []
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
        currentStyle = style
        rebuildHoverWindows()
    }

    @objc private func handleScreenParametersChanged() {
        // Display connect/disconnect and lid open/close can move, resize, or
        // remove the notch/edge entirely — rebuild every window's frame from
        // scratch rather than trying to patch geometry in place.
        cancelPendingReveal()
        rebuildHoverWindows()
    }

    // MARK: - Hover window lifecycle

    private func rebuildHoverWindows() {
        hoverWindows.forEach { $0.orderOut(nil) }
        hoverWindows.removeAll()

        guard currentStyle != .off else { return }

        for screen in NSScreen.screens {
            let info = EdgeRevealGeometry.screenInfo(for: screen)
            guard let zone = EdgeRevealGeometry.triggerZone(for: currentStyle, screenInfo: info) else { continue }
            let outsetZone = zone.insetBy(dx: -Self.hitTestOutset, dy: -Self.hitTestOutset)
            let window = EdgeRevealHoverWindow(
                zoneFrame: outsetZone,
                onEnter: { [weak self] in self?.handleZoneEntered() },
                onExit: { [weak self] in self?.handleZoneExited() }
            )
            window.orderFrontRegardless()
            hoverWindows.append(window)
        }
    }

    // MARK: - Event handling

    private func handleZoneEntered() {
        guard !AppState.shared.isVisible else { return }

        cancelPendingReveal()
        let style = currentStyle
        let work = DispatchWorkItem { [weak self] in
            self?.pendingReveal = nil
            // Re-check on fire: the dwell only proves the cursor didn't leave,
            // and the bar may have been opened another way meanwhile.
            guard !AppState.shared.isVisible else { return }
            AppState.shared.showCommandBar(revealStyle: style, openedBy: .mouse)
        }
        pendingReveal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dwellDelay, execute: work)
    }

    private func handleZoneExited() {
        // Leaving the zone abandons an in-flight dwell, so a cursor merely
        // passing through never opens the bar.
        cancelPendingReveal()
    }

    private func cancelPendingReveal() {
        pendingReveal?.cancel()
        pendingReveal = nil
    }
}
