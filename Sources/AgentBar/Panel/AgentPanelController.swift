import AppKit
import SwiftUI
import Combine
import CommandBarKit

/// Owns the floating panel: builds it, places it on the screen the cursor is
/// on, keeps its height in step with the content, and hides it on Esc or a
/// click outside. The panel is exactly the size of its content (unlike
/// FastTab's screen-sized canvas), so a click outside it never reaches it;
/// a global mouse monitor turns that click into a dismissal instead.
@MainActor
final class AgentPanelController {
    let model: AgentPanelModel
    private let panel: CommandBarPanel
    private var placementFrame = NSScreen.main?.visibleFrame ?? .zero
    private var outsideClickMonitor: Any?
    private var sizeSubscription: AnyCancellable?
    private let activation: TextInputActivation
    private var focusObservers: [NSObjectProtocol] = []

    /// Fires with true after the panel is shown and false after it is hidden,
    /// however that happened (Esc, outside click, a switch).
    var onVisibilityChange: ((Bool) -> Void)?

    /// The gear / ⌘, was used; called after the panel has closed itself.
    var onOpenSettings: (() -> Void)?

    init(model: AgentPanelModel, activation: TextInputActivation) {
        self.model = model
        self.activation = activation
        self.panel = Self.makePanel()
        let view = AgentPanelView(
            model: model,
            onClose: { [weak self] in self?.hide() },
            onOpenSettings: { [weak self] in
                self?.hide(restoringFocus: false)   // Settings takes the front itself
                self?.onOpenSettings?()
            }
        )
        let host = NSHostingController(rootView: view)
        host.sizingOptions = []   // the window frame is ours, not the content's
        panel.contentViewController = host
        // Publishers emit before the property changes, so use the emitted values.
        sizeSubscription = Publishers.CombineLatest4(
            model.$presentation,
            model.$listSettings,
            model.$peek.map { $0 != nil }.removeDuplicates(),
            Publishers.CombineLatest4(
                model.answer.$card.map { $0 != nil },
                model.permission.$card.map { $0 != nil },
                model.message.$card.map { $0 != nil },
                Publishers.CombineLatest3(
                    model.$query.map { AgentPanelMetrics.searchFieldLineCount(for: $0) }.removeDuplicates(),
                    model.$routingState.map { $0 != nil }.removeDuplicates(),
                    // Tagged: the chip lives inline in the search field itself (no extra row), but it
                    // does hide the list/status message below — a third, independent size input.
                    model.$taggedAgentID.map { $0 != nil }.removeDuplicates()
                )
            )
        )
        .sink { [weak self] presentation, listSettings, isPeeking, cardsAndSearchArea in
            let (answerOpen, permissionOpen, messageOpen, searchArea) = cardsAndSearchArea
            let (searchFieldLineCount, showsRoutingRow, isComposing) = searchArea
            self?.applySize(
                for: presentation, listSettings: listSettings, isPeeking: isPeeking,
                isAnswering: answerOpen || permissionOpen || messageOpen, isComposing: isComposing,
                searchFieldLineCount: searchFieldLineCount, showsRoutingRow: showsRoutingRow
            )
        }
    }

    var isVisible: Bool { panel.isVisible }

    func show() {
        model.resetForShow()
        placementFrame = SummonScreen.visibleFrame(fallback: placementFrame)
        applySize(
            for: model.presentation, listSettings: model.listSettings,
            isPeeking: model.peek != nil, isAnswering: model.isCardOpen
        )
        panel.makeKeyAndOrderFront(nil)
        startOutsideClickMonitor()
        startFocusObservers()
        activation.panelDidShow()
        onVisibilityChange?(true)
    }

    /// `restoringFocus: false` when the caller brings another window to the front itself
    /// (Settings, an agent switch), so the previous app is not activated in between.
    /// `isAgentSwitch`: the hide is for an agent switch; if the switch fails and the panel returns, focus is
    /// still handed back correctly (`TextInputActivation`).
    func hide(restoringFocus: Bool = true, isAgentSwitch: Bool = false) {
        let wasVisible = panel.isVisible
        stopOutsideClickMonitor()
        stopFocusObservers()
        panel.orderOut(nil)
        activation.panelDidHide(restoringFocus: restoringFocus, handingOffToAgentSwitch: isAgentSwitch)
        if wasVisible { onVisibilityChange?(false) }
    }

    private func applySize(
        for presentation: AgentListPresentation,
        listSettings: AgentListSettings,
        isPeeking: Bool,
        isAnswering: Bool,
        isComposing: Bool = false,
        searchFieldLineCount: Int = 1,
        showsRoutingRow: Bool = false
    ) {
        let maxListHeight = AgentPanelMetrics.maxListHeight(visibleRows: listSettings.maxVisibleRows)
        let height = AgentPanelMetrics.height(
            for: presentation, maxListHeight: maxListHeight, isPeeking: isPeeking, isAnswering: isAnswering,
            isComposing: isComposing, searchFieldLineCount: searchFieldLineCount, showsRoutingRow: showsRoutingRow
        )
        let size = CGSize(width: AgentPanelMetrics.width, height: height)
        panel.setFrame(AgentPanelPlacement.frame(size: size, in: placementFrame), display: panel.isVisible, animate: false)
    }

    private func startOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        // Global monitors only see clicks in other apps, i.e. outside the panel.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
    }

    /// Once AgentBar is the active app (a card text box is open), clicks in other apps no longer
    /// reach the global monitor above; the app losing the front is the signal instead. That
    /// dismisses the panel without handing focus back: the user chose the other app.
    private func startFocusObservers() {
        guard focusObservers.isEmpty else { return }
        let center = NotificationCenter.default
        let resign = center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.panel.isVisible, self.activation.isActive else { return }
                self.activation.appResignedActive()
                self.hide()
            }
        }
        let appeared = center.addObserver(forName: AnswerTextView.didAppearNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.activation.textInputAppeared() }
        }
        focusObservers = [resign, appeared]
    }

    private func stopFocusObservers() {
        focusObservers.forEach(NotificationCenter.default.removeObserver)
        focusObservers = []
    }

    private func stopOutsideClickMonitor() {
        guard let monitor = outsideClickMonitor else { return }
        NSEvent.removeMonitor(monitor)
        outsideClickMonitor = nil
    }

    private static func makePanel() -> CommandBarPanel {
        let panel = CommandBarPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "AgentBar"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.configureCommandBarOverlayBehavior()
        return panel
    }
}
