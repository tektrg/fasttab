import Foundation
import IndieAgentSessions
import IndieWorkspace

/// Brings forward the Antigravity window already showing a conversation or project title
/// (matched via Accessibility web page titles). False when none or several windows match, or
/// reading takes longer than 150 ms: the caller then falls back to `openURL` or activating the app.
@MainActor
enum AntigravityWindowRaiser {
    private static let control = AXWindowControl()
    private static let bundleID = AgentSessionHost.antigravityBundleIdentifier

    /// Call at launch so Electron publishes its web pages to Accessibility before the first jump.
    static func warmUp() { control.enableWebAccessibility(bundleID: bundleID) }

    static func raiseWindow(showing title: String) -> Bool {
        let wanted = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty,
              let windows = control.webPageTitles(bundleID: bundleID, budget: 0.15),
              windows.count > 1 else { return false }
        let hits = windows.indices.filter { index in
            windows[index].contains { pageTitle in
                pageTitle.localizedCaseInsensitiveContains(wanted)
            }
        }
        guard hits.count == 1 else { return false }
        return control.raise(bundleID: bundleID, windowIndex: hits[0], activate: true)
    }
}
