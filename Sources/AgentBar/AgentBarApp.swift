import SwiftUI
import AppKit

/// Bundle id, also the UserDefaults domain for AgentBar's own settings.
enum AgentBarIdentity {
    static let bundleIdentifier = "com.trungluong.AgentBar"
}

@MainActor
final class AgentBarAppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AgentBarCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-less background app: no dock icon, no menu bar.
        NSApp.setActivationPolicy(.accessory)

        let coordinator = AgentBarCoordinator()
        self.coordinator = coordinator
        coordinator.start()
    }

    /// Launching the app again (e.g. `open AgentBar.app`) summons the panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        coordinator?.showPanel()
        return false
    }
}

@main
struct AgentBarApp: App {
    @NSApplicationDelegateAdaptor(AgentBarAppDelegate.self) private var appDelegate

    var body: some Scene {
        // SwiftUI requires at least one scene; the real UI is the floating panel.
        Settings { EmptyView() }
    }
}
