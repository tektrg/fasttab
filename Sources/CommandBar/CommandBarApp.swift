import SwiftUI
import AppKit
import OSLog
import Combine

private let appLogger = Logger(subsystem: "com.trungluong.CommandBar", category: "AppDelegate")

@MainActor
class AppState: ObservableObject {
    @Published var isVisible: Bool = false
    @Published var selectedIndex: Int = 0
    @Published var hasAccessibilityAccess: Bool = false
    @Published var isRecordingShortcut: Bool = false
    let browserService = BrowserTabService()
    
    static let shared = AppState()
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        hasAccessibilityAccess = AccessibilityService.isTrusted()
        
        browserService.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }
    
    func refreshPermissions() {
        hasAccessibilityAccess = AccessibilityService.isTrusted()
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var globalMonitor: Any?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        let trusted = AXIsProcessTrusted()
        appLogger.info("Application did finish launching. AXIsProcessTrusted=\(trusted)")
        NSApp.setActivationPolicy(.regular)
        setupGlobalShortcut()
    }

    private func setupGlobalShortcut() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { event in
            let keyCode = event.keyCode
            let masked = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            Task { @MainActor in
                let store = ShortcutStore.shared
                guard keyCode == store.keyCode, masked == store.modifiers else { return }

                let appState = AppState.shared
                appLogger.info("Global shortcut \(store.displayString) detected. isVisible=\(appState.isVisible)")
                if !appState.isVisible {
                    appState.isVisible = true
                    appState.selectedIndex = 0
                    appState.browserService.fetchTabs()
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.windows.first?.makeKeyAndOrderFront(nil)
                } else {
                    appState.isVisible = false
                    NSApp.hide(nil)
                }
            }
        }

        if globalMonitor == nil {
            appLogger.error("Failed to register global monitor — Accessibility permission likely missing.")
        } else {
            appLogger.info("Global monitor registered successfully.")
        }
    }
}

@main
struct CommandBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState.shared
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
        }
        .windowStyle(.hiddenTitleBar)
    }
}
