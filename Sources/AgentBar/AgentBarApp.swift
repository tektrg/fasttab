import SwiftUI
import AppKit

/// Bundle id, also the UserDefaults domain for AgentBar's own settings.
enum AgentBarIdentity {
    static let bundleIdentifier = "com.trungluong.AgentBar"
}

@MainActor
final class AgentBarAppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AgentBarCoordinator?
    private var pendingURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-less background app: no dock icon, no menu bar.
        NSApp.setActivationPolicy(.accessory)
        CrashLog.install()
        CleanQuitMarker.standard.markLaunched()
        KeyboardDebugLog.start()
        ClaudeWindowRaiser.warmUp()
        AntigravityWindowRaiser.warmUp()

        let coordinator = AgentBarCoordinator()
        self.coordinator = coordinator
        coordinator.start()
        closeStraySettingsWindows()
        for url in pendingURLs { coordinator.openSessionLink(url) }
        pendingURLs = []
    }

    /// A normal quit only (not a crash/kill): tells the Pro's keep-alive not to relaunch.
    func applicationWillTerminate(_ notification: Notification) {
        CleanQuitMarker.standard.markCleanQuit()
    }

    /// `agentbar://session/<id>` links (scheme registered by `scripts/build-agentbar-app.sh`).
    func application(_ application: NSApplication, open urls: [URL]) {
        if urls.contains(where: ClaudeAXDump.handles) { ClaudeAXDump.run(); return }
        guard let coordinator else {
            pendingURLs += urls   // a link that launched the app may arrive before launch finishes
            return
        }
        for url in urls { coordinator.openSessionLink(url) }
    }

    /// Launching the app again (e.g. `open AgentBar.app`) summons the panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        coordinator?.showPanel()
        return false
    }

    func showSettings() { coordinator?.showSettings() }

    /// Belt and braces for `StraySettingsWindow`: if SwiftUI ever shows its own Settings window
    /// again, it is closed as soon as it appears (it is never the real Settings).
    private func closeStraySettingsWindows() {
        let close: (Notification) -> Void = { note in
            guard let window = note.object as? NSWindow,
                  StraySettingsWindow.isStray(identifier: window.identifier?.rawValue) else { return }
            DispatchQueue.main.async { window.close() }
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didChangeOcclusionStateNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main, using: close)
        }
        for window in NSApp.windows where StraySettingsWindow.isStray(identifier: window.identifier?.rawValue) {
            window.close()
        }
    }
}

/// SwiftUI's own `Settings` scene (window id `com_apple_SwiftUI_Settings_window`) is only a
/// placeholder: the real Settings is `SettingsWindowController`'s window. Once AgentBar is
/// frontmost (`TextInputActivation`, Focus mode, Settings) the app's main menu is live, so ⌘,
/// or any `showSettingsWindow:` reached the placeholder and drew an empty "AgentBar Settings"
/// window, and SwiftUI also showed it by itself at launch (observed on the Pro, every relaunch).
/// The app therefore has no `Settings` scene at all (a never-inserted `MenuBarExtra` satisfies
/// SwiftUI's one-scene rule); any window with this identifier is closed on sight.
enum StraySettingsWindow {
    static let swiftUISettingsIdentifierPrefix = "com_apple_SwiftUI_Settings_window"

    static func isStray(identifier: String?) -> Bool {
        guard let identifier else { return false }
        return identifier.hasPrefix(swiftUISettingsIdentifierPrefix)
    }
}

@main
struct AgentBarApp: App {
    @NSApplicationDelegateAdaptor(AgentBarAppDelegate.self) private var appDelegate

    var body: some Scene {
        // SwiftUI requires one scene; a `Settings` scene here opened an empty window by itself
        // (`StraySettingsWindow`). This one is never inserted, so it draws nothing.
        // ⌘, / "Settings…" open the real Settings window.
        MenuBarExtra("AgentBar", isInserted: .constant(false)) { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { appDelegate.showSettings() }
                        .keyboardShortcut(",", modifiers: .command)
                }
            }
    }
}
