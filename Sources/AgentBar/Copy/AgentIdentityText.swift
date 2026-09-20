import Foundation

/// What "Copy" puts on the pasteboard for an agent: one labelled line per known fact, so
/// it can be pasted into a chat or a terminal to say exactly which agent is meant.
/// Lines with nothing to say are left out. The dashboard row carries no machine name,
/// so there is no machine line.
///
///     Agent: fix-login
///     Pane: w6:pX
///     Project: command-bar-macos
///     Folder: /Users/me/command-bar-macos
///     Session: 3f2a…
enum AgentIdentityText {
    static func text(label: String, paneId: String?, projectName: String?, cwd: String?, sessionId: String?) -> String {
        [("Agent", label), ("Pane", paneId), ("Project", projectName), ("Folder", cwd), ("Session", sessionId)]
            .compactMap { name, value in
                guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
                return "\(name): \(value)"
            }
            .joined(separator: "\n")
    }
}

extension AgentSnapshot {
    var identityText: String {
        AgentIdentityText.text(label: label, paneId: paneId, projectName: projectName, cwd: cwd, sessionId: sessionId)
    }
}
