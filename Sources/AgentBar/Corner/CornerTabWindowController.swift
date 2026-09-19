import AppKit
import SwiftUI
import CommandBarKit

/// The corner tab's window: a small non-activating panel that never takes
/// keyboard focus, configured like the main panel (same level, same behaviour
/// over full-screen apps). Slides its content in and out; thin AppKit glue.
@MainActor
final class CornerTabWindowController {
    static let slideSeconds: TimeInterval = 0.25
    /// Lets the off-screen starting position render before the slide-in begins.
    private static let slideInDelaySeconds: TimeInterval = 0.03

    private let state = CornerTabViewState()
    private let panel: NSPanel
    /// Invalidates a pending "order out after sliding" when the tab comes back.
    private var hideGeneration = 0

    init(onClick: @escaping () -> Void) {
        panel = Self.makePanel()
        let host = NSHostingController(rootView: CornerTabView(state: state, onClick: onClick))
        host.sizingOptions = []
        panel.contentViewController = host
    }

    /// The window's frame while it is on screen.
    var frame: CGRect? { panel.isVisible ? panel.frame : nil }

    func show(_ content: CornerTabContent) {
        hideGeneration += 1
        state.content = content
        state.isSlidIn = false
        let screenFrame = SummonScreen.visibleFrame(fallback: NSScreen.main?.visibleFrame ?? .zero)
        panel.setFrame(CornerTabPlacement.windowFrame(in: screenFrame), display: true)
        panel.orderFrontRegardless()
        let generation = hideGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.slideInDelaySeconds) { [weak self] in
            guard let self, generation == hideGeneration else { return }
            slide(in: true)
        }
    }

    func update(_ content: CornerTabContent) {
        state.content = content
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
        panel.configureCommandBarOverlayBehavior()
        return panel
    }
}

/// Never key, never main: the tab must not take focus from what the user is typing in.
private final class TabPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
