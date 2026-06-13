import SwiftUI
import AppKit
import OSLog
import Combine

private let appLogger = Logger(subsystem: "com.trungluong.FastTab", category: "AppDelegate")
let fastTabCycleShortcutNotification = Notification.Name("FastTabCycleShortcut")
let fastTabPresentLicenseActivationNotification = Notification.Name("FastTabPresentLicenseActivation")

@MainActor
class AppState: ObservableObject {
    @Published var isVisible: Bool = false
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
        isVisible = commandWindow?.isVisible ?? false
    }

    func showCommandBar() {
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
        commandWindow.orderFrontRegardless()
        commandWindow.makeKey()
        isVisible = commandWindow.isVisible
        presentPendingLicenseActivationIfNeeded()
    }

    func hideCommandBar() {
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        appLogger.info("Application did finish launching")
        NSApp.setActivationPolicy(.accessory)
        CommandBarPanelController.shared.prepare()
        setupGlobalShortcut()
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

    override func sendEvent(_ event: NSEvent) {
        if event.isMouseDownEvent {
            let screenLocation = convertPoint(toScreen: event.locationInWindow)

            if CommandBarLayout.shouldDismissClick(at: screenLocation, in: frame) {
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
        installOutsideAppClickMonitor()
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

    private func installOutsideAppClickMonitor() {
        guard globalMouseDownMonitor == nil else { return }

        let eventMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

        globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: eventMask) { _ in
            DispatchQueue.main.async {
                AppState.shared.hideCommandBar()
            }
        }
    }
}

private extension NSEvent {
    var isMouseDownEvent: Bool {
        type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
    }
}

private extension NSWindow {
    func configureCommandBarOverlayBehavior() {
        styleMask.insert(.nonactivatingPanel)
        level = .floating

        var behavior = collectionBehavior
        behavior.remove(.moveToActiveSpace)
        behavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary, .stationary])
        collectionBehavior = behavior
    }

    func fitCommandBarCanvasToVisibleScreen(preferMouseScreen: Bool) {
        let displayFrame = preferredCommandBarDisplay(preferMouseScreen: preferMouseScreen)?.visibleFrame ?? NSScreen.main?.visibleFrame ?? frame
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
