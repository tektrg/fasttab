import AppKit
import SwiftUI
import IndieCommandBar

/// Focus mode's window: one borderless panel covering the screen under the pointer ONLY (other
/// screens untouched), above every window and full-screen app (`.canJoinAllSpaces`,
/// `.fullScreenAuxiliary`, one level above the AgentBar panel). Blur (an `NSVisualEffectView`
/// behind the SwiftUI dim) + black 45%/60% dim + the centred card. Fades in over 180ms (card
/// 0.98→1; Reduce Motion: crossfade only). Non-activating like the AgentBar panel, but becomes KEY
/// so the keys below work; a text box appearing activates the app through the shared
/// `TextInputActivation` (gotcha 12), same as the panel and the corner card.
///
/// Keys (a local monitor): ↑/↓ options · 1–9 pick · ↩ answer · ⌘←/⌘→ agents · ⌘↩ open terminal ·
/// Esc exit. Esc, ⌘←/⌘→ and ⌘↩ work even while a text box has the keyboard; everything else
/// (↩ sends, arrows, digits) is the box's while typing.
@MainActor
final class FocusOverlayController {
    static let level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
    static let fadeSeconds: TimeInterval = 0.18

    private let model: AgentPanelModel
    private let activation: TextInputActivation
    private var panel: CommandBarPanel?
    private var session: FocusSession?
    private var keyMonitor: Any?
    private var observers: [NSObjectProtocol] = []

    /// Called with true when Focus mode opens and false when it closes (the corner tab steps aside).
    var onVisibilityChange: (Bool) -> Void = { _ in }
    /// ⌘↩ / Open terminal: switch to the agent (Focus mode closes first).
    var onOpenTerminal: (AgentSnapshot) -> Void = { _ in }

    init(model: AgentPanelModel, activation: TextInputActivation) {
        self.model = model
        self.activation = activation
    }

    var isVisible: Bool { panel != nil }

    /// Opens Focus mode. With nothing in the queue it shows "All clear" briefly and closes.
    func show() {
        guard panel == nil else { return }
        model.resetForShow()
        let session = FocusSession(model: model)
        session.onExit = { [weak self] in self?.hide() }
        session.onOpenTerminal = { [weak self] agent in
            self?.hide(restoringFocus: false, isAgentSwitch: true)
            self?.onOpenTerminal(agent)
        }
        self.session = session

        let screen = Self.screenUnderPointer()
        let panel = Self.makePanel(frame: screen.frame)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let root = FocusOverlayView(session: session, reduceMotion: reduceMotion, onExit: { [weak self] in self?.hide() })
        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: screen.frame.size))
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.autoresizingMask = [.width, .height]
        let host = NSHostingView(rootView: root)
        host.frame = blur.bounds
        host.autoresizingMask = [.width, .height]
        blur.addSubview(host)
        panel.contentView = blur
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeSeconds
            panel.animator().alphaValue = 1
        }
        self.panel = panel
        startKeyMonitor()
        startObservers()
        activation.panelDidShow()
        onVisibilityChange(true)
    }

    func hide(restoringFocus: Bool = true, isAgentSwitch: Bool = false) {
        guard let panel else { return }
        self.panel = nil
        stopKeyMonitor()
        stopObservers()
        session?.end()
        session = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.fadeSeconds
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        })
        activation.panelDidHide(restoringFocus: restoringFocus, handingOffToAgentSwitch: isAgentSwitch)
        onVisibilityChange(false)
    }

    // MARK: - Keys

    private func startKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            nonisolated(unsafe) let keyEvent = event
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, let panel = self.panel, keyEvent.window === panel else { return false }
                return self.handle(keyEvent, in: panel)
            }
            return consumed ? nil : event
        }
    }

    private func stopKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// True when the key was Focus mode's.
    private func handle(_ event: NSEvent, in panel: NSPanel) -> Bool {
        guard let session else { return false }
        let key = FocusKey(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers ?? "",
                           modifiers: event.modifierFlags.intersection([.command, .option, .control, .shift]))
        let isTyping = panel.firstResponder is NSTextView
        switch FocusKey.action(for: key, isTyping: isTyping) {
        case nil:
            return false
        case .exit:
            hide()
        case .openTerminal:
            session.openTerminal()
        case .previousAgent:
            session.moveBack()
        case .nextAgent:
            session.moveForward()
        case .move(let step):
            if session.phase == .allClear { return true }
            if model.answer.isOpen || model.permission.isOpen { model.moveSelectionOrAnswerHighlight(by: step) }
        case .pick(let number):
            if model.answer.isOpen || model.permission.isOpen { model.handleCardDigit(number) }
        case .space:
            if model.answer.isOpen { model.answer.handle(.space) }
        case .enter:
            if session.phase == .allClear { hide(); return true }
            if model.isCardOpen, !event.isARepeat { model.activateSelected() }
        }
        return true
    }

    // MARK: - Activation (dictation into a card text box)

    private func startObservers() {
        let center = NotificationCenter.default
        let appeared = center.addObserver(forName: AnswerTextView.didAppearNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.panel != nil { self?.activation.textInputAppeared() } }
        }
        observers = [appeared]
    }

    private func stopObservers() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    // MARK: - Window

    static func screenUnderPointer() -> NSScreen {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private static func makePanel(frame: NSRect) -> CommandBarPanel {
        let panel = CommandBarPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "AgentBar Focus"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.level = level
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovable = false
        panel.setFrame(frame, display: false)
        return panel
    }
}

/// Focus mode's key map (pure, unit-tested).
struct FocusKey: Equatable {
    enum Action: Equatable {
        case exit
        case openTerminal
        case previousAgent
        case nextAgent
        case move(Int)
        case pick(Int)
        case space
        case enter
    }

    static let returnKeyCode: UInt16 = 36
    static let keypadEnterKeyCode: UInt16 = 76
    static let escapeKeyCode: UInt16 = 53
    static let leftKeyCode: UInt16 = 123
    static let rightKeyCode: UInt16 = 124
    static let downKeyCode: UInt16 = 125
    static let upKeyCode: UInt16 = 126
    static let spaceKeyCode: UInt16 = 49

    let keyCode: UInt16
    let characters: String
    let modifiers: NSEvent.ModifierFlags

    static func == (lhs: FocusKey, rhs: FocusKey) -> Bool {
        lhs.keyCode == rhs.keyCode && lhs.characters == rhs.characters && lhs.modifiers == rhs.modifiers
    }

    /// Nil = not Focus mode's: the key goes on to the window (a text box, a button).
    /// While a text box has the keyboard only Esc, ⌘←/⌘→ and ⌘↩ are taken (↩, arrows, digits are the box's).
    static func action(for key: FocusKey, isTyping: Bool) -> Action? {
        let isReturn = key.keyCode == returnKeyCode || key.keyCode == keypadEnterKeyCode
        // Focus mode's own keys win in EVERY state, a focused text box included: a Message card
        // opens with its box focused, and handing it Esc / ⌘← / ⌘→ left the overlay stuck (Esc
        // closed the card, which Focus mode reopened at once; ⌘←/⌘→ only moved the caret).
        if isReturn, key.modifiers == .command { return .openTerminal }
        if key.keyCode == escapeKeyCode, key.modifiers.subtracting(.shift).isEmpty { return .exit }
        if key.modifiers == .command {
            switch key.keyCode {
            case leftKeyCode: return .previousAgent
            case rightKeyCode: return .nextAgent
            default: return nil
            }
        }
        if isTyping { return nil }   // plain ↩ (send), arrows, digits: the box's
        guard key.modifiers.subtracting(.shift).isEmpty else { return nil }
        switch key.keyCode {
        case upKeyCode: return .move(-1)
        case downKeyCode: return .move(1)
        case spaceKeyCode: return .space
        case _ where isReturn: return .enter
        default:
            if key.modifiers.isEmpty, let number = Int(key.characters), (1...9).contains(number) { return .pick(number) }
            return nil
        }
    }
}
