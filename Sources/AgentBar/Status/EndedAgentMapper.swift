import Foundation

/// Maps the delivery board's ended session rows into the "Ended" section.
///
/// An agent the user finished with Done is stopped, not closed: the board then
/// shows it as an ended row whose `actions.close` is still enabled because the
/// pane exists. Those rows are the second step of Done ("Stopped — pane still
/// open", with a Close pane button). After Close the board keeps the row as
/// "ended · closed by you"; that one is left out, since the user is done with it.
enum EndedAgentMapper {
    /// How recently a session must have ended to be listed. The board keeps
    /// them 72h; a day is what is still worth resuming from a switcher.
    static let endedWindowSeconds: TimeInterval = 24 * 60 * 60
    /// At most this many ended rows, newest first.
    static let maxEndedCount = 8

    /// Which ended rows to keep: how recent, and how many.
    struct Limits: Equatable, Sendable {
        var windowSeconds: TimeInterval
        var maxCount: Int

        /// The out-of-the-box list (24h, 8 rows).
        static let standard = Limits(windowSeconds: endedWindowSeconds, maxCount: maxEndedCount)
        /// Everything the Settings choices can ask for: the dashboard keeps 72h,
        /// and the largest "how many" choice is 16. The status snapshot carries
        /// this much; the list narrows it to the user's choice at display time.
        static let widest = Limits(windowSeconds: 72 * 60 * 60, maxCount: 16)
    }

    /// Board label for a row whose pane and session name are both gone.
    private static let unnamedRowLabel = "(no matching herdr pane)"
    private static let paneKeyedRowIdPrefix = "pane:"
    private static let closedByUserMarker = "closed by"
    private static let stoppedByUserMarker = "stopped by"
    static let stoppedPaneStatusText = "Stopped — pane still open"
    static let endedPaneStatusText = "Ended — pane still open"

    static func map(
        rows: [DashboardBoardRow],
        liveAgents: [AgentSnapshot],
        liveRowIds: Set<String>,
        serverNow: TimeInterval,
        limits: Limits = .standard
    ) -> [AgentSnapshot] {
        let livePaneIds = Set(liveAgents.compactMap(\.paneId))
        return rows
            .filter { $0.status == "ended" && $0.archived != true }
            .compactMap { row -> (endedTs: TimeInterval, snapshot: AgentSnapshot)? in
                // A pane-less ended row is a status-only session (Claude Desktop / CLI outside
                // herdr, `AgentHost`) that ended — or the old id of one that is still running after
                // /clear or a resume, which would list it twice. Nothing to close or open: left out.
                guard let paneId = row.paneId, !paneId.isEmpty, !livePaneIds.contains(paneId),
                      let endedTs = row.endedTs, serverNow - endedTs <= limits.windowSeconds,
                      let rowId = row.rowId, !liveRowIds.contains(rowId),
                      !wasClosedByUser(row),
                      let label = usableLabel(row.label) else { return nil }
                return (endedTs, snapshot(row: row, rowId: rowId, label: label, endedTs: endedTs, serverNow: serverNow))
            }
            .sorted { $0.endedTs > $1.endedTs }
            .prefix(limits.maxCount)
            .map(\.snapshot)
    }

    private static func wasClosedByUser(_ row: DashboardBoardRow) -> Bool {
        row.endedNote?.lowercased().contains(closedByUserMarker) ?? false
    }

    /// Ended rows with no real name ("(no matching herdr pane)", or the raw
    /// "pane:w6-pS" row id) tell the user nothing, so they are left out.
    private static func usableLabel(_ label: String?) -> String? {
        guard let label = label?.trimmingCharacters(in: .whitespacesAndNewlines),
              !label.isEmpty, label != unnamedRowLabel,
              !label.hasPrefix(paneKeyedRowIdPrefix) else { return nil }
        return label
    }

    private static func snapshot(
        row: DashboardBoardRow, rowId: String, label: String, endedTs: TimeInterval, serverNow: TimeInterval
    ) -> AgentSnapshot {
        let actions = AgentActions(decoded: row.actions, fallback: .none)
        // The server says Close is possible only while the pane still exists.
        let paneIsStillOpen = actions.close.isEnabled
        return AgentSnapshot(
            id: rowId,
            label: label,
            projectName: ProjectNameResolver.projectName(fromCwd: row.cwd),
            cwd: row.cwd,
            paneId: row.paneId,
            section: .ended,
            statusText: statusText(for: row, paneIsStillOpen: paneIsStillOpen),
            secondsInStatus: max(0, serverNow - endedTs),
            hasUnpushedCommits: false,
            unpushedText: nil,
            promptExcerpt: nil,
            canFocus: paneIsStillOpen && row.paneId != nil,
            hasHookData: true,
            rowId: rowId,
            actions: actions
        )
    }

    private static func statusText(for row: DashboardBoardRow, paneIsStillOpen: Bool) -> String {
        if paneIsStillOpen {
            let wasStopped = row.endedNote?.lowercased().contains(stoppedByUserMarker) ?? false
            return wasStopped ? stoppedPaneStatusText : endedPaneStatusText
        }
        return StatusTextCleaner.singleLine(row.endedNote, maxLength: LiveAgentMapper.statusTextMaxLength) ?? "Ended"
    }
}
