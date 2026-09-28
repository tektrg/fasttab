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
    /// Live agents arrive as `.needsYou` or `.working`; Park moves a needs-you
    /// row to `.parked` (`TriageState.applying`).
    private(set) var section: AgentSection
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
    /// The dashboard's row id (the session id): what stop/close are addressed to.
    /// Nil when the dashboard gave none.
    var rowId: String? = nil
    /// The Claude session id (locates its transcript); nil for opencode and plain shells.
    var sessionId: String? = nil
    /// Server-resolved Stop/Close availability. On an ended row, Close is
    /// enabled while the stopped agent's pane is still open.
    var actions: AgentActions = .none
    /// What the dashboard says the agent is blocked on, if it is blocked on a
    /// question or permission box. See `blockedOnYou` for what the list shows.
    var blocker: AgentBlocker? = nil
    /// herdr pane, or a status-only Claude Desktop / CLI session (no pane: no Answer, Message,
    /// Done, peek-at-screen; Enter opens Claude.app for a desktop session). See `AgentHost`.
    var host: AgentHost = .herdr
    /// A status-only session's prompt held by the dashboard's hook bridge: what its Answer / Review card
    /// shows and answers by id (no pane read). Nil for herdr rows, and when nothing is waiting.
    var hookRequest: HookRequest? = nil
    /// A status-only session that takes a message through its peer inbox right now (dashboard
    /// `messageVia: "inbox"`, and not waiting on a prompt). See `MessageRoute`.
    var messagesViaInbox: Bool = false

    /// The blocker while the row sits in Needs you. Parking sets a row aside, and
    /// with it the Blocked badge, the answer action and the top-of-section spot.
    var blockedOnYou: AgentBlocker? {
        section == .needsYou ? blocker : nil
    }

    /// The same agent shown under another section.
    func placed(in newSection: AgentSection) -> AgentSnapshot {
        var copy = self
        copy.section = newSection
        return copy
    }
}
