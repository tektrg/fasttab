import SwiftUI
import AppKit
import OSLog
import Combine

private let appLogger = Logger(subsystem: "com.trungluong.FastTab", category: "AppDelegate")
let fastTabCycleShortcutNotification = Notification.Name("FastTabCycleShortcut")
let fastTabPresentLicenseActivationNotification = Notification.Name("FastTabPresentLicenseActivation")

@MainActor
class AppState: ObservableObject {
    @Published var isVisible: Bool = false {
        didSet {
            guard isVisible != oldValue else { return }
            // The outside-click dismiss monitor is a *global* event monitor: it
            // wakes this process for every mouse-down anywhere on the Mac. Only
            // keep it installed while the bar is actually visible, otherwise a
            // hidden background app burns energy (and fires a publish storm) on
            // every click the user makes in any other app.
            if isVisible {
                CommandBarPanelController.shared.startOutsideClickMonitoring()
            } else {
                CommandBarPanelController.shared.stopOutsideClickMonitoring()
            }
        }
    }
    @Published var selectedIndex: Int = 0
    @Published var isRecordingShortcut: Bool = false
    @Published var globalShortcutRegistrationIssue: String?
    let browserService = BrowserTabService()

    static let shared = AppState()
    private var cancellables = Set<AnyCancellable>()
    private weak var commandWindow: NSWindow?
    private var didHideInitialWindow = false
    private var pendingShowAfterAttach = false
    private var pendingLicenseActivationPresentation = false

    init() {
        browserService.objectWillChange
            .debounce(for: .milliseconds(16), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        browserService.prewarmCaches()
    }

    func attachCommandWindow(_ window: NSWindow) {
        commandWindow = window

        if !didHideInitialWindow {
            didHideInitialWindow = true
            if !pendingShowAfterAttach {
                window.orderOut(nil)
                isVisible = false
            }
        }

        if pendingShowAfterAttach {
            pendingShowAfterAttach = false
            showCommandBar()
        }
    }

    var hasCommandWindow: Bool { commandWindow != nil }

    var isCommandWindowFrontAndActive: Bool {
        guard let commandWindow else { return false }
        return commandWindow.isVisible && commandWindow.isKeyWindow
    }

    var commandWindowDebugState: String {
        guard let commandWindow else { return "window=nil" }
        return "visible=\(commandWindow.isVisible) key=\(commandWindow.isKeyWindow) main=\(commandWindow.isMainWindow) appActive=\(NSApp.isActive)"
    }

    func syncVisibilityFromCommandWindow() {
        let next = commandWindow?.isVisible ?? false
        // @Published republishes even on same-value assignment, so guard to
        // avoid redundant SwiftUI invalidations on every window key/resign.
        if next != isVisible { isVisible = next }
    }

    /// - Parameter revealStyle: non-nil when this open was triggered by the
    ///   notch/edge hover reveal (`EdgeRevealService`), rather than the
    ///   keyboard shortcut or menu-bar icon. Plays a brief grow-from-that-side
    ///   animation instead of appearing instantly.
    func showCommandBar(revealStyle: EdgeRevealStyle? = nil) {
        LicenseService.shared.refreshTimeSensitiveState()

        guard let commandWindow else {
            pendingShowAfterAttach = true
            CommandBarPanelController.shared.prepare()

            if commandWindow == nil {
                appLogger.error("showCommandBar: commandWindow is nil and no opener available")
            }
            return
        }

        selectedIndex = -1
        browserService.updateCurrentFlowSourceApp(bundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        commandWindow.configureCommandBarOverlayBehavior()
        commandWindow.fitCommandBarCanvasToVisibleScreen(preferMouseScreen: true)

        // Arm the grow animation before the window is ordered front: it must
        // already be in its shrunk presentation state for the first rendered
        // frame, or the bar flashes at full size for a frame before shrinking.
        if let revealStyle {
            CommandBarPanelController.shared.playRevealAnimation(from: revealStyle)
        }

        commandWindow.orderFrontRegardless()
        commandWindow.makeKey()
        isVisible = commandWindow.isVisible
        presentPendingLicenseActivationIfNeeded()
    }

    func hideCommandBar() {
        guard isVisible || (commandWindow?.isVisible ?? false) else { return }
        commandWindow?.orderOut(nil)
        isVisible = false
    }

    func toggleCommandBar() {
        if isVisible {
            hideCommandBar()
        } else {
            showCommandBar()
        }
    }

    func requestLicenseActivationPresentation() {
        pendingLicenseActivationPresentation = true
        showCommandBar()
    }

    private func presentPendingLicenseActivationIfNeeded() {
        guard pendingLicenseActivationPresentation else { return }
        pendingLicenseActivationPresentation = false
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: fastTabPresentLicenseActivationNotification,
                object: nil
            )
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private let hotkeyService = GlobalHotkeyService()
    private var cancellables = Set<AnyCancellable>()
    /// Retained for the app's entire lifetime — never call `endActivity`.
    /// As an accessory app (`LSUIElement`) with no visible window, FastTab is
    /// exactly the profile macOS targets for App Nap. That throttles the run
    /// loop over time, which silently stops delivering the continuous global
    /// mouseMoved stream `EdgeRevealService` depends on for hover detection —
    /// it works right after launch, then goes quiet a short while later.
    private var appNapActivityToken: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        appLogger.info("Application did finish launching")
        NSApp.setActivationPolicy(.accessory)
        appNapActivityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Continuous global mouse tracking for notch/edge hover reveal"
        )
        CommandBarPanelController.shared.prepare()
        setupGlobalShortcut()
        EdgeRevealService.shared.start()
        LicenseService.shared.validateForLaunch()

        if OnboardingWindowController.shared.isNeeded {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                OnboardingWindowController.shared.show()
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            UpdateService.shared.checkForUpdates(manual: false)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            LicenseService.shared.handleActivationURL(url)
        }
    }

    private func setupGlobalShortcut() {
        let store = ShortcutStore.shared

        hotkeyService.onHotKeyPressed = { [weak self] in
            Task { @MainActor in
                self?.handleGlobalShortcut()
            }
        }

        applyGlobalShortcut(keyCode: store.keyCode, modifiers: store.modifiers)

        Publishers.CombineLatest(store.$keyCode, store.$modifiers)
            .sink { [weak self] keyCode, modifiers in
                self?.applyGlobalShortcut(keyCode: keyCode, modifiers: modifiers)
            }
            .store(in: &cancellables)

        appLogger.info("Global hotkey service registered for shortcut \(store.displayString)")
    }

    private func applyGlobalShortcut(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        let result = hotkeyService.registerShortcut(keyCode: keyCode, modifiers: modifiers)
        AppState.shared.globalShortcutRegistrationIssue = result.userMessage

        if let message = result.userMessage {
            appLogger.error("Global hotkey registration issue: \(message, privacy: .public)")
        }
    }

    private func handleGlobalShortcut() {
        let store = ShortcutStore.shared
        let appState = AppState.shared
        let shouldCycle = appState.isCommandWindowFrontAndActive

        appLogger.info("Global shortcut \(store.displayString) detected. isVisible=\(appState.isVisible) shouldCycle=\(shouldCycle) state=\(appState.commandWindowDebugState, privacy: .public)")

        if shouldCycle {
            NotificationCenter.default.post(name: fastTabCycleShortcutNotification, object: nil)
        } else {
            appState.showCommandBar()
        }
    }
}

@main
struct FastTabApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState.shared
    @StateObject private var updateService = UpdateService.shared
    @StateObject private var licenseService = LicenseService.shared

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(licenseService)
        }

        MenuBarExtra("FastTab", systemImage: "command") {
            Button(appState.isVisible ? "Hide FastTab" : "Show FastTab") {
                appState.toggleCommandBar()
            }

            Divider()

            Button("Buy FastTab…") {
                licenseService.openCheckout(source: .menuBar)
            }

            Button("Enter License Key…") {
                appState.requestLicenseActivationPresentation()
            }

            Button("Manage License…") {
                licenseService.openManageLicense()
            }

            Divider()

            SettingsLink {
                Text("Settings…")
            }

            Button("Feedback & Support…") {
                licenseService.openSupport()
            }

            Divider()

            Button("Check for Updates…") {
                updateService.checkForUpdates(manual: true)
            }

            switch updateService.status {
            case .available(let version, _):
                Button("Update to v\(version)") {
                    updateService.performPrimaryAction()
                }
            case .readyToRestart(let version):
                Button("Restart to Update v\(version)") {
                    updateService.performPrimaryAction()
                }
            default:
                EmptyView()
            }

            Button("Quit") {
                NSApp.terminate(nil)
            }
        }
        .menuBarExtraStyle(.menu)
    }
}

private final class CommandBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// AppKit's default behavior pushes any window whose frame reaches into the
    /// menu bar strip back down below it. That silently shrank the full-screen
    /// canvas we set in `fitCommandBarCanvasToVisibleScreen`, leaving a
    /// menu-bar-height gap between the notch-anchored bar and the true top of
    /// the display. Returning the rect unchanged keeps the canvas flush.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    override func sendEvent(_ event: NSEvent) {
        if event.isMouseDownEvent {
            let screenLocation = convertPoint(toScreen: event.locationInWindow)

            if CommandBarLayout.shouldDismissClick(at: screenLocation, in: frame, anchor: EdgeRevealStyle.commandBarAnchor) {
                AppState.shared.hideCommandBar()
                return
            }
        }

        super.sendEvent(event)
    }
}

@MainActor
private final class CommandBarPanelController: NSObject {
    static let shared = CommandBarPanelController()

    private var panel: CommandBarPanel?
    private weak var observedWindow: NSWindow?
    private var globalMouseDownMonitor: Any?

    func prepare() {
        _ = commandPanel
    }

    private var commandPanel: CommandBarPanel {
        if let panel { return panel }

        let rootView = ContentView()
            .environmentObject(AppState.shared)
            .environmentObject(LicenseService.shared)

        let panel = CommandBarPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.identifier = NSUserInterfaceItemIdentifier("command-bar-panel")
        panel.title = "Command Bar"
        panel.contentViewController = NSHostingController(rootView: rootView)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.configureCommandBarOverlayBehavior()
        panel.fitCommandBarCanvasToVisibleScreen(preferMouseScreen: true)

        installWindowObservers(for: panel)
        AppState.shared.attachCommandWindow(panel)
        AppState.shared.syncVisibilityFromCommandWindow()

        self.panel = panel
        return panel
    }

    private func installWindowObservers(for window: NSWindow) {
        guard observedWindow !== window else { return }

        observedWindow = window

        let center = NotificationCenter.default
        center.removeObserver(self)

        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.willCloseNotification
        ]

        for name in names {
            center.addObserver(
                self,
                selector: #selector(handleObservedWindowChange),
                name: name,
                object: window
            )
        }

        center.addObserver(
            self,
            selector: #selector(handleScreenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func handleObservedWindowChange() {
        AppState.shared.syncVisibilityFromCommandWindow()
    }

    @objc private func handleScreenParametersChanged() {
        guard let observedWindow, observedWindow.isVisible else { return }
        observedWindow.fitCommandBarCanvasToVisibleScreen(preferMouseScreen: false)
    }

    /// Arms the SwiftUI-native grow-from-edge reveal animation (see
    /// `CommandBarRevealTrigger`/`ContentView`) instead of the instant
    /// appearance used by the keyboard shortcut. Must run before the window
    /// is ordered front so the first rendered frame is already in its
    /// shrunk state, matching the same requirement the previous CALayer-based
    /// version had — a raw `CABasicAnimation` on the whole (screen-sized)
    /// content-view layer read as the bar sliding into place rather than
    /// expanding from the edge, since the anchor was applied to the entire
    /// canvas rather than just the visible surface within it.
    func playRevealAnimation(from style: EdgeRevealStyle) {
        CommandBarRevealTrigger.shared.fire(anchor: style)
    }

    func startOutsideClickMonitoring() {
        guard globalMouseDownMonitor == nil else { return }

        let eventMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

        globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: eventMask) { _ in
            DispatchQueue.main.async {
                guard AppState.shared.isVisible else { return }
                AppState.shared.hideCommandBar()
            }
        }
    }

    func stopOutsideClickMonitoring() {
        guard let monitor = globalMouseDownMonitor else { return }
        NSEvent.removeMonitor(monitor)
        globalMouseDownMonitor = nil
    }
}

private extension NSEvent {
    var isMouseDownEvent: Bool {
        type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
    }
}

extension NSWindow {
    func configureCommandBarOverlayBehavior() {
        styleMask.insert(.nonactivatingPanel)
        // Above the menu bar (`.mainMenu`), not merely `.floating`: the bar now
        // sits flush against the true top of the display, so at `.floating` the
        // menu bar painted over its top strip — invisible with a translucent
        // menu bar, but an opaque band under Reduce Transparency.
        level = .statusBar

        var behavior = collectionBehavior
        behavior.remove(.moveToActiveSpace)
        behavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary, .stationary])
        collectionBehavior = behavior
    }

    func fitCommandBarCanvasToVisibleScreen(preferMouseScreen: Bool) {
        // Full screen frame, not `visibleFrame` — `visibleFrame` excludes the
        // menu bar strip, which left a gap between the notch anchor and the
        // true top edge of the display instead of sitting flush against it.
        let displayFrame = preferredCommandBarDisplay(preferMouseScreen: preferMouseScreen)?.frame ?? NSScreen.main?.frame ?? frame
        let canvasFrame = CommandBarLayout.canvasFrame(for: displayFrame)

        setFrame(canvasFrame, display: true, animate: false)
    }

    private func preferredCommandBarDisplay(preferMouseScreen: Bool) -> NSScreen? {
        if preferMouseScreen {
            let mouseLocation = NSEvent.mouseLocation

            if let mouseScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) {
                return mouseScreen
            }
        }

        return screen ?? NSScreen.main
    }
}
