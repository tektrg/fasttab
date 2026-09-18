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

    init(model: AgentPanelModel) {
        self.model = model
        self.panel = Self.makePanel()
        model.onActivate = { [weak self] _ in
            // Slice 4 focuses the agent here; for now activating just closes.
            self?.hide()
        }
        let host = NSHostingController(rootView: AgentPanelView(model: model, onClose: { [weak self] in self?.hide() }))
        host.sizingOptions = []   // the window frame is ours, not the content's
        panel.contentViewController = host
        sizeSubscription = model.$presentation.sink { [weak self] presentation in
            self?.applySize(for: presentation)
        }
    }

    var isVisible: Bool { panel.isVisible }

    func show() {
        model.resetForShow()
        placementFrame = (NSScreen.containing(NSEvent.mouseLocation) ?? NSScreen.main)?.visibleFrame ?? placementFrame
        applySize(for: model.presentation)
        panel.makeKeyAndOrderFront(nil)
        startOutsideClickMonitor()
    }

    func hide() {
        stopOutsideClickMonitor()
        panel.orderOut(nil)
    }

    private func applySize(for presentation: AgentListPresentation) {
        let size = CGSize(width: AgentPanelMetrics.width, height: AgentPanelMetrics.height(for: presentation))
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
