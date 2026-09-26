import Foundation

/// Where a live agent runs, from the dashboard row's `source`. Only herdr agents have a
/// pane AgentBar can read, type into, answer or focus through the dashboard. The other two are
/// **status-only rows** (dashboard `claude_sessions.py`): Claude sessions the dashboard sees
/// through Claude's own session files, with no herdr pane behind them.
enum AgentHost: Equatable, Sendable {
    /// A herdr pane (`source: "herdr"`, or no `source` from an older dashboard).
    case herdr
    /// A Claude Desktop (Claude.app) code session. `openURL` (`claude://code/continue?session=…`)
    /// brings Claude.app to that session; nil when the dashboard gave none.
    case claudeDesktop(openURL: URL?)
    /// The Claude CLI outside herdr (e.g. in tmux). `tmuxTarget` ("session:@w.%p") when known.
    case claudeCLI(tmuxTarget: String?)

    static let claudeDesktopBundleIdentifier = "com.anthropic.claudefordesktop"

    /// Reads the wire fields; nil for a `source` this build does not know (the row is then
    /// treated as herdr when it has a pane, dropped otherwise — see `LiveAgentMapper`).
    init?(source: String?, openUrl: String?, tmuxTarget: String?) {
        switch source {
        case nil, "herdr":
            self = .herdr
        case "claude-desktop":
            self = .claudeDesktop(openURL: openUrl.flatMap { $0.isEmpty ? nil : URL(string: $0) })
        case "claude-cli":
            self = .claudeCLI(tmuxTarget: tmuxTarget.flatMap { $0.isEmpty ? nil : $0 })
        default:
            return nil
        }
    }

    var isHerdr: Bool { self == .herdr }

    /// The small tag next to the project name telling a status-only row apart; nil for herdr.
    var badgeText: String? {
        switch self {
        case .herdr: nil
        case .claudeDesktop: "Claude Desktop"
        case .claudeCLI(let tmuxTarget): tmuxTarget == nil ? "CLI" : "CLI · tmux"
        }
    }
}
