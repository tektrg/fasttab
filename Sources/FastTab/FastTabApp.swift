import SwiftUI
import AppKit
import OSLog
import Combine

private let appLogger = Logger(subsystem: "com.trungluong.FastTab", category: "AppDelegate")
let fastTabCycleShortcutNotification = Notification.Name("FastTabCycleShortcut")

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

        guard !didHideInitialWindow else { return }
        didHideInitialWindow = true
        window.orderOut(nil)
        isVisible = false
    }

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

    func showCommandBar() {
        selectedIndex = -1
        NSApp.activate(ignoringOtherApps: true)
        commandWindow?.makeKeyAndOrderFront(nil)
        commandWindow?.orderFrontRegardless()
        isVisible = commandWindow?.isVisible ?? true
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
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private let hotkeyService = GlobalHotkeyService()
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        appLogger.info("Application did finish launching")
        NSApp.setActivationPolicy(.accessory)
        setupGlobalShortcut()
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
    @StateObject private var launchAtLogin = LaunchAtLoginService.shared

    var body: some Scene {
        WindowGroup("Command Bar", id: "command-bar") {
            ContentView()
                .environmentObject(appState)
                .background(WindowChromeConfigurator())
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 760, height: 580)
        .windowResizability(.contentSize)

        MenuBarExtra("FastTab", systemImage: "command") {
            Button(appState.isVisible ? "Hide Command Bar" : "Open Command Bar") {
                appState.toggleCommandBar()
            }

            Divider()

            Toggle("Launch at Login", isOn: Binding(
                get: { launchAtLogin.isEnabled },
                set: { launchAtLogin.setEnabled($0) }
            ))

            if let errorMessage = launchAtLogin.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Divider()

            Button("Quit") {
                NSApp.terminate(nil)
            }
        }
        .menuBarExtraStyle(.menu)
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
        }

        @objc private func handleObservedWindowChange() {
            AppState.shared.syncVisibilityFromCommandWindow()
        }
    }
}
