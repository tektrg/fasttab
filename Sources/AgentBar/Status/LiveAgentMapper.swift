import Foundation

/// Maps the dashboard's live agent rows into `AgentSnapshot`s.
enum LiveAgentMapper {
    static let statusTextMaxLength = 120
    static let promptExcerptMaxLength = 300

    static func map(
        agents: [DashboardAgent],
        needsYou: [DashboardNeedsYou],
        board: BoardIndex
    ) -> [AgentSnapshot] {
        let needsYouByPaneId = Dictionary(
            needsYou.compactMap { entry -> (String, DashboardNeedsYou)? in
                guard entry.kind == "question" || entry.kind == "blocked",
                      let paneId = entry.paneId, !paneId.isEmpty else { return nil }
                return (paneId, entry)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let snapshots = agents.compactMap { snapshot(for: $0, needsYouByPaneId: needsYouByPaneId, board: board) }
        // Sections in display order; the server's order is kept within a section.
        return snapshots.enumerated()
            .sorted { ($0.element.section, $0.offset) < ($1.element.section, $1.offset) }
            .map(\.element)
    }

    private static func snapshot(
        for agent: DashboardAgent,
        needsYouByPaneId: [String: DashboardNeedsYou],
        board: BoardIndex
    ) -> AgentSnapshot? {
        // Residue = a leftover hook file whose pane is gone; nothing to switch to.
        guard agent.residue != true, let paneId = agent.paneId, !paneId.isEmpty else { return nil }
        let needsYouEntry = needsYouByPaneId[paneId]
        let section = AgentSectionClassifier.section(
            hookState: agent.hookState,
            screenState: agent.screenState,
            paneIsInDashboardNeedsYou: needsYouEntry != nil
        )
        let sessionId = agent.agentSession.flatMap { $0.isEmpty ? nil : $0 }
        let pushText = board.unpushedText(rowId: agent.rowId, paneId: paneId)
        let questionText = StatusTextCleaner.singleLine(agent.screenQuestion?.question, maxLength: promptExcerptMaxLength)
        let screenSignal = StatusTextCleaner.singleLine(agent.screenSignal, maxLength: statusTextMaxLength)
        return AgentSnapshot(
            id: sessionId ?? paneId,
            label: agent.label ?? "",
            projectName: ProjectNameResolver.projectName(fromCwd: agent.cwd),
            cwd: agent.cwd,
            paneId: paneId,
            section: section,
            statusText: statusText(section: section, agent: agent, screenSignal: screenSignal),
            secondsInStatus: needsYouEntry?.sinceSec ?? agent.hookSinceSec,
            hasUnpushedCommits: pushText != nil,
            unpushedText: pushText,
            promptExcerpt: questionText ?? StatusTextCleaner.singleLine(agent.screenSignal, maxLength: promptExcerptMaxLength),
            canFocus: true,
            hasHookData: agent.hasHookData ?? false
        )
    }

    private static func statusText(section: AgentSection, agent: DashboardAgent, screenSignal: String?) -> String {
        let hookReason = StatusTextCleaner.singleLine(agent.hookReason, maxLength: statusTextMaxLength)
        switch section {
        case .needsYou:
            // The question title names what is being asked; for a plain permission
            // prompt the screen line is the prompt itself (the hook reason is
            // only generic vendor copy) — same precedence as the dashboard.
            let title = StatusTextCleaner.singleLine(agent.screenQuestion?.title, maxLength: statusTextMaxLength)
            return title ?? screenSignal ?? hookReason ?? "Waiting for your answer"
        case .working:
            return screenSignal ?? hookReason ?? "Working"
        case .idle, .ended:
            return screenSignal ?? hookReason ?? "Idle"
        }
    }
}
