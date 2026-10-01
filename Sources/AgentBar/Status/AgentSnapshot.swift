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
    /// Remote (Air) panes: seconds since the dashboard saw the pane's screen change (dashboard
    /// `screenActivitySec`, ~15s granularity); nil when unseen or for any other row. Ranking only — never
    /// status, sounds or `hasHookData`. Read it through `activitySeconds`.
    var screenActivitySeconds: TimeInterval? = nil
    let hasUnpushedCommits: Bool
    /// The dashboard's marker text, e.g. "3 ahead — not pushed".
    let unpushedText: String?
    /// Text to match a search query against besides label/project: the
    /// pending question, else the last screen line.
    let promptExcerpt: String?
    /// False for ended rows and anything without a live pane.
    let canFocus: Bool
    /// False for non-Claude panes (plain shells, other CLIs) and for Claude panes on another machine (the
    /// hook cache is this Mac's only): their section is read off the screen. "Is it Claude?" is `isClaude`.
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
    /// A herdr row the dashboard says it types messages into (`messageVia: "pane"`). Lets a pane row
    /// with no hook data (a Claude agent on another machine, e.g. the Air) take a message; the
    /// dashboard's `messageRefusal` still has the last word. See `RowButtons.messageRoute`.
    var messagesViaPane: Bool = false
    /// "opencode" | "codex" for a herdr row of that tool with fresh exact status (dashboard `agentKind`); nil for
    /// Claude. Such a row takes a message as a plain prompt: no `/compact` / `/clear`, no leading `/` or `!`.
    var messageTool: String? = nil
    /// The dashboard's reason it would refuse a message to this row (`messageRefusal`); nil = it would not.
    var messageRefusal: String? = nil
    /// The dashboard says this agent can Read an image attached from this Mac (`acceptsImages`): false for an
    /// agent on another machine (e.g. the Air), whose Message card then takes no images. Absent = true.
    var acceptsImages: Bool = true
    /// herdr's tool for a herdr row (dashboard `agentKind`: "claude" | "opencode" | "codex" | …); nil for a
    /// status-only row, an ended/sleeping row, or an older dashboard. See `isClaude`.
    var agentKind: String? = nil
    /// The dashboard says this agent is waiting on the user's answer (its Needs-you list, or a screen
    /// that needs a human) — `LiveAgentMapper`'s `hasPrompt`. Unlike `blocker` it does not mean there
    /// is an Answer/Review card: a Claude Desktop / CLI session waiting without a held hook request has
    /// this but no blocker. Ranking only — see `isWaitingOnYou`.
    var awaitsPrompt: Bool = false

    /// How long ago the agent itself last did something: `secondsInStatus` (hook / needs-you clock), else the
    /// screen-change clock a hook-less remote pane has. Nil = unknown (ranks oldest). Mirrors the dashboard's
    /// `personas.row_activity_sec`.
    var activitySeconds: TimeInterval? { secondsInStatus ?? screenActivitySeconds }

    /// The blocker while the row sits in Needs you. Parking sets a row aside, and
    /// with it the Blocked badge, the answer action and the top-of-section spot.
    var blockedOnYou: AgentBlocker? {
        section == .needsYou ? blocker : nil
    }

    /// Ranks the row in the top "waiting on you" tier (`AgentRanking`, `AgentListGrouping`): blocked on
    /// an answerable prompt, or waiting on the user without one. Parked rows never do (same as
    /// `blockedOnYou`). Buttons, corner card and sounds keep keying on `blockedOnYou` alone.
    var isWaitingOnYou: Bool {
        section == .needsYou && (blocker != nil || awaitsPrompt)
    }

    /// A Claude agent: herdr says `claude` (hook data or not — an Air pane never has any), or a status-only
    /// Desktop/CLI session. With no kind (older dashboard, ended/sleeping rows) hook data stands in, as before.
    var isClaude: Bool {
        guard host.isHerdr else { return true }
        if let agentKind { return agentKind == "claude" }
        return hasHookData
    }

    /// A non-Claude pane whose status is only a screen guess (a plain shell; OpenCode/Codex without its
    /// plugin/hook): setting "Show non-Claude panes" hides it and the list dims it. A Claude agent on another
    /// machine and an OpenCode/Codex pane with exact status are first-class.
    var isBestGuessNonClaudePane: Bool { !isClaude && !hasHookData }

    /// The same agent shown under another section.
    func placed(in newSection: AgentSection) -> AgentSnapshot {
        var copy = self
        copy.section = newSection
        return copy
    }
}
