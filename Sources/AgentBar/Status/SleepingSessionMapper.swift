import Foundation

/// One `computed.sleepingSessions` entry: a Claude Desktop session with no running process
/// (dashboard `desktop_sessions.py`). Already deduped against live rows server-side.
struct DashboardSleepingSession: Decodable {
    /// Claude Desktop's own id, "local_<uuid>".
    let desktopSessionId: String?
    /// The Claude Code session id (its transcript); nil when Desktop never recorded one.
    let cliSessionId: String?
    /// Desktop's title for the session, else its folder name.
    let label: String?
    let cwd: String?
    /// Last activity, server clock (seconds).
    let lastActiveTs: Double?
    /// `claude://code/continue?session=local_…`.
    let openUrl: String?

    private enum CodingKeys: String, CodingKey { case desktopSessionId, cliSessionId, label, cwd, lastActiveTs, openUrl }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        desktopSessionId = container.lenient(.desktopSessionId)
        cliSessionId = container.lenient(.cliSessionId)
        label = container.lenient(.label)
        cwd = container.lenient(.cwd)
        lastActiveTs = container.lenient(.lastActiveTs)
        openUrl = container.lenient(.openUrl)
    }
}

/// Maps sleeping Claude Desktop sessions into the "Sleeping" section: greyed, status-free rows whose
/// Enter opens the session in Claude.app (same `AgentHost.claudeDesktop` path as a live Desktop row).
/// Which of them the list shows (list days vs search days) is `AgentListSettings`' call.
enum SleepingSessionMapper {
    static let statusPrefix = "Sleeping"

    /// Newest first, one row per id (the newest): the dashboard already dedupes, but two rows with
    /// one id would break list selection, so it is enforced here too.
    static func map(_ sessions: [DashboardSleepingSession], serverNow: TimeInterval) -> [AgentSnapshot] {
        var seenIDs = Set<String>()
        return sessions
            .compactMap { snapshot(for: $0, serverNow: serverNow) }
            .sorted { ($0.secondsInStatus ?? 0) < ($1.secondsInStatus ?? 0) }
            .filter { seenIDs.insert($0.id).inserted }
    }

    /// "Sleeping · 2d ago".
    static func statusText(secondsSinceActive: TimeInterval) -> String {
        "\(statusPrefix) · \(AgentAge.shortText(secondsSinceActive)) ago"
    }

    private static func snapshot(for session: DashboardSleepingSession, serverNow: TimeInterval) -> AgentSnapshot? {
        let cliSessionId = nonEmpty(session.cliSessionId)
        // Keyed like the live row this session becomes when it wakes (its Claude session id), so
        // frecency and selection carry over.
        guard let id = cliSessionId ?? nonEmpty(session.desktopSessionId),
              let lastActiveTs = session.lastActiveTs,
              case .claudeDesktop(let openURL)? = AgentHost(source: "claude-desktop", openUrl: session.openUrl, tmuxTarget: nil)
        else { return nil }
        let secondsSinceActive = max(0, serverNow - lastActiveTs)
        let label = StatusTextCleaner.singleLine(session.label, maxLength: LiveAgentMapper.statusTextMaxLength)
        return AgentSnapshot(
            id: id,
            label: label ?? ProjectNameResolver.projectName(fromCwd: session.cwd) ?? id,
            projectName: ProjectNameResolver.projectName(fromCwd: session.cwd),
            cwd: session.cwd,
            paneId: nil,
            section: .sleeping,
            statusText: statusText(secondsSinceActive: secondsSinceActive),
            secondsInStatus: secondsSinceActive,
            hasUnpushedCommits: false,
            unpushedText: nil,
            promptExcerpt: nil,
            canFocus: true,
            hasHookData: true,
            sessionId: cliSessionId,
            host: .claudeDesktop(openURL: openURL)
        )
    }

    private static func nonEmpty(_ text: String?) -> String? {
        text.flatMap { $0.isEmpty ? nil : $0 }
    }
}
