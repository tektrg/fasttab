import Foundation

/// Maps the delivery board's ended session rows into the "Ended" section.
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
                guard let endedTs = row.endedTs, serverNow - endedTs <= limits.windowSeconds,
                      let rowId = row.rowId, !liveRowIds.contains(rowId),
                      row.paneId.map({ !livePaneIds.contains($0) }) ?? true,
                      let label = usableLabel(row.label) else { return nil }
                return (endedTs, snapshot(row: row, rowId: rowId, label: label, endedTs: endedTs, serverNow: serverNow))
            }
            .sorted { $0.endedTs > $1.endedTs }
            .prefix(limits.maxCount)
            .map(\.snapshot)
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
        AgentSnapshot(
            id: rowId,
            label: label,
            projectName: ProjectNameResolver.projectName(fromCwd: row.cwd),
            cwd: row.cwd,
            paneId: row.paneId,
            section: .ended,
            statusText: StatusTextCleaner.singleLine(row.endedNote, maxLength: LiveAgentMapper.statusTextMaxLength) ?? "Ended",
            secondsInStatus: max(0, serverNow - endedTs),
            hasUnpushedCommits: false,
            unpushedText: nil,
            promptExcerpt: nil,
            canFocus: false,
            hasHookData: true
        )
    }
}
