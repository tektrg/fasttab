import AppKit
import SwiftUI
import CommandBarKit

/// The corner tab's window: a small non-activating panel, configured like the main panel (same
/// level, same behaviour over full-screen apps). As the pill it never takes keyboard focus at all;
/// as a card it can become key, but only when a control inside it actually needs it (a text field
/// clicked for "Other"/feedback), never from a plain click on a button or option row
/// (`becomesKeyOnlyIfNeeded`, `TabPanel.canBecomeKey`) — so a card sitting there passively never
/// steals the keyboard from whatever the user is doing elsewhere. Slides its content in and out;
/// thin AppKit glue.
@MainActor
final class CornerTabWindowController {
    static let slideSeconds: TimeInterval = 0.25
    /// Lets the off-screen starting position render before the slide-in begins.
    private static let slideInDelaySeconds: TimeInterval = 0.03

    private let state = CornerTabViewState()
    private let panel: NSPanel
    /// Invalidates a pending "order out after sliding" when the tab comes back.
    private var hideGeneration = 0

    init(
        model: AgentPanelModel, onClick: @escaping () -> Void, onDismiss: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void
    ) {
        panel = Self.makePanel()
        let host = NSHostingController(
            rootView: CornerTabView(
                state: state, model: model, onOpenPanel: onClick, onDismiss: onDismiss, onOpenSettings: onOpenSettings
            )
        )
        host.sizingOptions = []
        panel.contentViewController = host
    }

    /// The window's frame while it is on screen.
    var frame: CGRect? { panel.isVisible ? panel.frame : nil }

    /// A fresh pill appearance (the window was hidden): always slides in.
    func show(_ content: CornerTabContent) {
        showPill(content)
    }

    /// The pill is already up (or, having just been a card, needs to become one): a plain text
    /// refresh needs no animation; a mode change is shown like a fresh appearance.
    func update(_ content: CornerTabContent) {
        guard state.mode == .card else {
            state.content = content
            return
        }
        showPill(content)
    }

    /// A fresh card appearance (the window was hidden): always slides in.
    func showCard() {
        hideGeneration += 1
        state.mode = .card
        state.isSlidIn = false
        panel.hasShadow = true
        present(frame: CornerTabPlacement.cardWindowFrame(in: screenFrame()))
    }

    /// The card is already up: its content follows the model on its own, nothing to do. Only a
    /// mode change (the pill was showing instead) needs the fresh-appearance treatment.
    func updateCard() {
        guard state.mode == .pill else { return }
        showCard()
    }

    private func showPill(_ content: CornerTabContent) {
        hideGeneration += 1
        state.mode = .pill
        state.content = content
        state.isSlidIn = false
        panel.hasShadow = false
        present(frame: CornerTabPlacement.windowFrame(in: screenFrame()))
    }

    private func screenFrame() -> CGRect {
        SummonScreen.visibleFrame(fallback: NSScreen.main?.visibleFrame ?? .zero)
    }

    private func present(frame: CGRect) {
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        let generation = hideGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.slideInDelaySeconds) { [weak self] in
            guard let self, generation == hideGeneration else { return }
            slide(in: true)
        }
    }

    func slideOut() {
        hideGeneration += 1
        let generation = hideGeneration
        slide(in: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.slideSeconds + 0.05) { [weak self] in
            guard let self, generation == hideGeneration else { return }
            panel.orderOut(nil)
        }
    }

    /// No animation: used when the panel takes the tab's place.
    func removeNow() {
        hideGeneration += 1
        state.isSlidIn = false
        panel.orderOut(nil)
    }

    private func slide(in slidesIn: Bool) {
        // Reduce Motion: appear and disappear without travelling.
        let animation: Animation? = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? nil : .easeOut(duration: Self.slideSeconds)
        withAnimation(animation) { state.isSlidIn = slidesIn }
    }

    private static func makePanel() -> NSPanel {
        let panel = TabPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "AgentBar corner tab"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.becomesKeyOnlyIfNeeded = true
        panel.configureCommandBarOverlayBehavior()
        return panel
    }
}

/// Never main; can become key, but `becomesKeyOnlyIfNeeded` (set on the instance above) means a
/// plain click on the pill or a card's buttons/option rows never triggers it — only a control that
/// itself demands key status (a text field's `becomeFirstResponder`) does. `.nonactivatingPanel`
/// (the style mask) keeps even that from activating the app on its own.
private final class TabPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
