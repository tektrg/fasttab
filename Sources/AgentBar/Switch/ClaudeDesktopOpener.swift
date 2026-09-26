import AppKit

/// Brings a Claude Desktop code session forward: the session's own deep link first
/// (`claude://code/continue?session=…` navigates Claude.app to that existing session), else
/// just Claude.app. Behind a protocol so `AgentSwitchCoordinator` is tested without opening apps.
@MainActor
protocol ClaudeDesktopOpening {
    /// False when neither the link nor the app could be opened.
    func openSession(_ url: URL?) -> Bool
}

/// The real one. `openURL` / `activateApp` are the two system calls, injectable so the
/// link-then-app fallback order is unit-tested.
@MainActor
struct ClaudeDesktopOpener: ClaudeDesktopOpening {
    var openURL: @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }
    var activateApp: @MainActor (String) -> Bool = Self.activateOrLaunch(bundleIdentifier:)

    func openSession(_ url: URL?) -> Bool {
        if let url, openURL(url) { return true }
        return activateApp(AgentHost.claudeDesktopBundleIdentifier)
    }

    /// Activates the running app, else launches it; false when it is not installed.
    private static func activateOrLaunch(bundleIdentifier: String) -> Bool {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first {
            NSApp.yieldActivation(to: running)
            return running.activate(options: [])
        }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return false }
        NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
        return true
    }
}
