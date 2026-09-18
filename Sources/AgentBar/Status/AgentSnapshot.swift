import Foundation

/// One row of the switcher: a live agent pane, or a recently ended session.
struct AgentSnapshot: Identifiable, Equatable, Sendable {
    /// Session id when the agent has one, else the pane id. Stable across
    /// updates, so it is safe to key frecency and selection on.
    let id: String
    /// Tab label chosen by the user (what they recognise the agent by).
    let label: String
    /// Repo/folder name derived from `cwd`; nil when the cwd is unknown.
    let projectName: String?
    let cwd: String?
    /// herdr pane id, e.g. "w6:pX". Nil for ended rows that never had one.
    let paneId: String?
    let section: AgentSection
    /// Short, single-line description of what the agent is doing / asking.
    let statusText: String
    /// Seconds the agent has been in its current status, as of the server's
    /// clock at fetch time. Nil when unknown. UI may add `now - fetchedAt`.
    let secondsInStatus: TimeInterval?
    let hasUnpushedCommits: Bool
    /// The dashboard's marker text, e.g. "3 ahead — not pushed".
    let unpushedText: String?
    /// Text to match a search query against besides label/project: the
    /// pending question, else the last screen line.
    let promptExcerpt: String?
    /// False for ended rows and anything without a live pane.
    let canFocus: Bool
    /// False for non-Claude panes (plain shells, other CLIs): no hook data,
    /// so their section is a best guess.
    let hasHookData: Bool
}
