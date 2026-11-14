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
        KeyboardDebugLog.start()

        let coordinator = AgentBarCoordinator()
        self.coordinator = coordinator
        coordinator.start()
        for url in pendingURLs { coordinator.openSessionLink(url) }
        pendingURLs = []
    }

    /// `agentbar://session/<id>` links (scheme registered by `scripts/build-agentbar-app.sh`).
    func application(_ application: NSApplication, open urls: [URL]) {
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
}

/// SwiftUI's own `Settings` scene (window id `com_apple_SwiftUI_Settings_window`) is only a
/// placeholder: the real Settings is `SettingsWindowController`'s window. Once AgentBar is
/// frontmost (`TextInputActivation`, Focus mode, Settings) the app's main menu is live, so ⌘,
/// or any `showSettingsWindow:` reached the placeholder and drew an empty "AgentBar Settings"
/// window. Any such window is closed on sight and the real Settings opens instead.
enum StraySettingsWindow {
    static let swiftUISettingsIdentifierPrefix = "com_apple_SwiftUI_Settings_window"

    static func isStray(identifier: String?) -> Bool {
        guard let identifier else { return false }
        return identifier.hasPrefix(swiftUISettingsIdentifierPrefix)
    }
}

/// Content of the placeholder scene: never shown for long, it redirects to the real Settings.
private struct SettingsSceneRedirect: View {
    let openRealSettings: () -> Void

    var body: some View {
        Color.clear.frame(width: 1, height: 1).onAppear {
            DispatchQueue.main.async {
                for window in NSApp.windows where StraySettingsWindow.isStray(identifier: window.identifier?.rawValue) {
                    window.close()
                }
                openRealSettings()
            }
        }
    }
}

@main
struct AgentBarApp: App {
    @NSApplicationDelegateAdaptor(AgentBarAppDelegate.self) private var appDelegate

    var body: some Scene {
        // SwiftUI requires at least one scene; the real UI is the floating panel.
        // ⌘, / "Settings…" open the real Settings window; the placeholder scene redirects if
        // anything still reaches it (`StraySettingsWindow`).
        Settings { SettingsSceneRedirect { appDelegate.showSettings() } }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { appDelegate.showSettings() }
                        .keyboardShortcut(",", modifiers: .command)
                }
            }
    }
}
