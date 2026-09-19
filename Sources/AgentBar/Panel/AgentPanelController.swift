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

    /// Fires with true after the panel is shown and false after it is hidden,
    /// however that happened (Esc, outside click, a switch).
    var onVisibilityChange: ((Bool) -> Void)?

    /// The gear / ⌘, was used; called after the panel has closed itself.
    var onOpenSettings: (() -> Void)?

    init(model: AgentPanelModel) {
        self.model = model
        self.panel = Self.makePanel()
        let view = AgentPanelView(
            model: model,
            onClose: { [weak self] in self?.hide() },
            onOpenSettings: { [weak self] in
                self?.hide()
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
            model.answer.$card.map { $0 != nil }.removeDuplicates()
        )
        .sink { [weak self] presentation, listSettings, isPeeking, isAnswering in
            self?.applySize(for: presentation, listSettings: listSettings, isPeeking: isPeeking, isAnswering: isAnswering)
        }
    }

    var isVisible: Bool { panel.isVisible }

    /// The panel's frame while it is on screen.
    var visibleFrame: CGRect? { panel.isVisible ? panel.frame : nil }

    func show() {
        model.resetForShow()
        placementFrame = SummonScreen.visibleFrame(fallback: placementFrame)
        applySize(
            for: model.presentation, listSettings: model.listSettings,
            isPeeking: model.peek != nil, isAnswering: model.answer.isOpen
        )
        panel.makeKeyAndOrderFront(nil)
        startOutsideClickMonitor()
        onVisibilityChange?(true)
    }

    func hide() {
        let wasVisible = panel.isVisible
        stopOutsideClickMonitor()
        panel.orderOut(nil)
        if wasVisible { onVisibilityChange?(false) }
    }

    private func applySize(
        for presentation: AgentListPresentation,
        listSettings: AgentListSettings,
        isPeeking: Bool,
        isAnswering: Bool
    ) {
        let maxListHeight = AgentPanelMetrics.maxListHeight(visibleRows: listSettings.maxVisibleRows)
        let height = AgentPanelMetrics.height(
            for: presentation, maxListHeight: maxListHeight, isPeeking: isPeeking, isAnswering: isAnswering
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
