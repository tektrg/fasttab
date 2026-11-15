import Foundation
import IndieAgentSessions
import IndieWorkspace

/// Brings forward the Claude Desktop window already showing a chat (matched by the page title
/// "<chat> - Claude Code", `ClaudeWindowMatch`). False when none or several windows show it, or
/// reading takes longer than 150 ms: the caller then uses the session link.
@MainActor
enum ClaudeWindowRaiser {
    private static let control = AXWindowControl()
    private static let bundleID = AgentSessionHost.claudeDesktopBundleIdentifier

    /// Call at launch: Claude needs a moment to publish its pages to Accessibility the first time.
    static func warmUp() { control.enableWebAccessibility(bundleID: bundleID) }

    static func raiseWindow(showing title: String) -> Bool {
        guard let windows = control.webPageTitles(bundleID: bundleID, budget: 0.15),
              windows.count > 1,   // one window: the link already lands in it
              let index = ClaudeWindowMatch.window(showing: title, in: windows) else { return false }
        return control.raise(bundleID: bundleID, windowIndex: index, activate: true)
    }
}
