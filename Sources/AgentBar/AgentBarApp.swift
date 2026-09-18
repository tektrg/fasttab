import SwiftUI
import AppKit

/// Bundle id, also the UserDefaults domain for AgentBar's own settings.
enum AgentBarIdentity {
    static let bundleIdentifier = "com.trungluong.AgentBar"
}

@MainActor
final class AgentBarAppDelegate: NSObject, NSApplicationDelegate {
    private let statusSource = DashboardStatusSource()
    private var panelController: AgentPanelController?
    private var feedTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-less background app: no dock icon, no menu bar.
        NSApp.setActivationPolicy(.accessory)

        let controller = AgentPanelController(model: AgentPanelModel())
        panelController = controller
        startStatusFeed(into: controller.model)
        controller.show()
    }

    /// Launching the app again (e.g. `open AgentBar.app`) summons the panel.
    /// Slice 4 adds the global hotkey for the same.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panelController?.show()
        return false
    }

    private func startStatusFeed(into model: AgentPanelModel) {
        let source = statusSource
        Task { await source.start() }
        feedTask = Task { @MainActor in
            for await snapshot in source.updates {
                model.receive(snapshot)
            }
        }
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
