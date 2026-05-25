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
    var openCommandWindow: (() -> Void)?

    init() {
        browserService.objectWillChange
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
        return commandWindow.isVisible && commandWindow.isKeyWindow && NSApp.isActive
    }

    var commandWindowDebugState: String {
        guard let commandWindow else { return "window=nil" }
        return "visible=\(commandWindow.isVisible) key=\(commandWindow.isKeyWindow) main=\(commandWindow.isMainWindow) appActive=\(NSApp.isActive)"
    }

    func syncVisibilityFromCommandWindow() {
        isVisible = commandWindow?.isVisible ?? false
    }

    static func findCommandWindow() -> NSWindow? {
        // Look for the SwiftUI WindowGroup's NSWindow. The Settings scene
        // shows up as NSPanel; the command bar window is a content-bearing
        // NSWindow whose title matches the WindowGroup's title.
        for window in NSApp.windows {
            if window.identifier?.rawValue.hasPrefix("command-bar") == true { return window }
            if window.title == "Command Bar" { return window }
        }
        return nil
    }

    func showCommandBar() {
        LicenseService.shared.refreshTimeSensitiveState()

        guard let commandWindow else {
            // Window not yet materialized — common when launched at login with
            // .accessory activation policy, where SwiftUI defers WindowGroup
            // creation. Ask SwiftUI to open it; attachCommandWindow will
            // re-invoke showCommandBar once the NSWindow is wired up.
            pendingShowAfterAttach = true
            if let fallback = AppState.findCommandWindow() {
                attachCommandWindow(fallback)
            } else if let openCommandWindow {
                openCommandWindow()
            } else {
                appLogger.error("showCommandBar: commandWindow is nil and no opener available")
            }
            return
        }

        selectedIndex = -1
        browserService.updateCurrentFlowSourceApp(bundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        NSApp.activate(ignoringOtherApps: true)
        commandWindow.fitCommandBarCanvasToVisibleScreen(preferMouseScreen: true)
        commandWindow.makeKeyAndOrderFront(nil)
        commandWindow.orderFrontRegardless()
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

        // When launched at login, SwiftUI's WindowGroup may not push its
        // NSView hierarchy through `viewDidMoveToWindow` until something
        // forces a layout, so AppState.commandWindow can stay nil. Probe
        // NSApp.windows shortly after launch and attach manually if needed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let state = AppState.shared
            if !state.hasCommandWindow, let window = AppState.findCommandWindow() {
                appLogger.info("Eagerly attaching command window discovered in NSApp.windows")
                state.attachCommandWindow(window)
            }
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
        WindowGroup("Command Bar", id: "command-bar") {
            ContentView()
                .environmentObject(appState)
                .environmentObject(licenseService)
                .background(WindowChromeConfigurator())
                .onOpenURL { url in
                    licenseService.handleActivationURL(url)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: CommandBarLayout.defaultCanvasSize.width, height: CommandBarLayout.defaultCanvasSize.height)
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(licenseService)
        }

        MenuBarExtra("FastTab", systemImage: "command") {
            MenuBarOpenWindowBinder()

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

private struct MenuBarOpenWindowBinder: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                AppState.shared.openCommandWindow = {
                    openWindow(id: "command-bar")
                }
            }
    }
}

private struct WindowChromeConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> ConfigView {
        ConfigView()
    }

    func updateNSView(_ nsView: ConfigView, context: Context) {
        nsView.configureWindowIfNeeded()
    }

    final class ConfigView: NSView {
        private var didConfigure = false
        private weak var observedWindow: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureWindowIfNeeded()
        }

        func configureWindowIfNeeded() {
            guard !didConfigure, let window else { return }
            didConfigure = true

            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.isMovableByWindowBackground = true
            window.collectionBehavior.insert([.moveToActiveSpace, .fullScreenAuxiliary])
            window.fitCommandBarCanvasToVisibleScreen(preferMouseScreen: true)

            [NSWindow.ButtonType.closeButton,
             .miniaturizeButton,
             .zoomButton].forEach { type in
                guard let button = window.standardWindowButton(type) else { return }
                button.isHidden = true
                button.isEnabled = false
            }

            installWindowObservers(for: window)

            Task { @MainActor in
                AppState.shared.attachCommandWindow(window)
                AppState.shared.syncVisibilityFromCommandWindow()
            }
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
    }
}

private extension NSWindow {
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
