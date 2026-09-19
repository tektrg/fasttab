import Foundation

/// Maps the dashboard's live agent rows into `AgentSnapshot`s: every live agent
/// is `.working` or `.needsYou` (see `AgentSectionClassifier`).
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
        // Sections in display order; inside Needs you an agent with a real prompt
        // comes before one that merely finished; the server's order is kept otherwise.
        return snapshots.enumerated()
            .sorted { ($0.element.snapshot.section, $0.element.hasPrompt ? 0 : 1, $0.offset)
                < ($1.element.snapshot.section, $1.element.hasPrompt ? 0 : 1, $1.offset) }
            .map(\.element.snapshot)
    }

    private static func snapshot(
        for agent: DashboardAgent,
        needsYouByPaneId: [String: DashboardNeedsYou],
        board: BoardIndex
    ) -> (snapshot: AgentSnapshot, hasPrompt: Bool)? {
        // Residue = a leftover hook file whose pane is gone; nothing to switch to.
        guard agent.residue != true, let paneId = agent.paneId, !paneId.isEmpty else { return nil }
        let needsYouEntry = needsYouByPaneId[paneId]
        let hasPrompt = AgentSectionClassifier.isAwaitingPrompt(
            screenState: agent.screenState, paneIsInDashboardNeedsYou: needsYouEntry != nil
        )
        let section = AgentSectionClassifier.section(
            hookState: agent.hookState,
            screenState: agent.screenState,
            paneIsInDashboardNeedsYou: needsYouEntry != nil
        )
        let sessionId = agent.agentSession.flatMap { $0.isEmpty ? nil : $0 }
        let pushText = board.unpushedText(rowId: agent.rowId, paneId: paneId)
        let questionText = StatusTextCleaner.singleLine(agent.screenQuestion?.question, maxLength: promptExcerptMaxLength)
        let screenSignal = StatusTextCleaner.singleLine(agent.screenSignal, maxLength: statusTextMaxLength)
        let snapshot = AgentSnapshot(
            id: sessionId ?? paneId,
            label: agent.label ?? "",
            projectName: ProjectNameResolver.projectName(fromCwd: agent.cwd),
            cwd: agent.cwd,
            paneId: paneId,
            section: section,
            statusText: statusText(
                section: section, hasPrompt: hasPrompt, agent: agent, needsYouEntry: needsYouEntry, screenSignal: screenSignal
            ),
            secondsInStatus: needsYouEntry?.sinceSec ?? agent.hookSinceSec,
            hasUnpushedCommits: pushText != nil,
            unpushedText: pushText,
            promptExcerpt: questionText ?? StatusTextCleaner.singleLine(agent.screenSignal, maxLength: promptExcerptMaxLength),
            canFocus: true,
            hasHookData: agent.hasHookData ?? false,
            rowId: agent.rowId,
            sessionId: sessionId,
            actions: AgentActions(decoded: agent.actions, fallback: .unknown),
            blocker: blocker(for: needsYouEntry)
        )
        return (snapshot, hasPrompt)
    }

    /// A "question" row is answerable once its parsed picker has arrived (until
    /// then it is loading); a "blocked" row is a permission box (or unconfirmed prompt).
    private static func blocker(for needsYouEntry: DashboardNeedsYou?) -> AgentBlocker? {
        switch needsYouEntry?.kind {
        case "question":
            if needsYouEntry?.question == nil { return .questionLoading(needsYouEntry?.questionPreview?.identity) }
            return AnswerableQuestion(needsYouEntry?.question).map(AgentBlocker.question) ?? .questionNotAnswerable
        case "blocked":
            return .permission
        default:
            return nil
        }
    }

    private static func statusText(
        section: AgentSection,
        hasPrompt: Bool,
        agent: DashboardAgent,
        needsYouEntry: DashboardNeedsYou?,
        screenSignal: String?
    ) -> String {
        let hookReason = StatusTextCleaner.singleLine(agent.hookReason, maxLength: statusTextMaxLength)
        switch section {
        case .needsYou where hasPrompt:
            // The question (its title, then its text) is what is being asked. The dashboard's own
            // `detail` comes next: for a hook-preview question ("options loading")
            // it is fresher than the screen line, which is then stale. For a plain
            // permission prompt the screen line is the prompt itself (the hook
            // reason is only generic vendor copy) — same precedence as the dashboard.
            let title = StatusTextCleaner.singleLine(agent.screenQuestion?.title, maxLength: statusTextMaxLength)
            let question = StatusTextCleaner.singleLine(agent.screenQuestion?.question, maxLength: statusTextMaxLength)
            let asked = [title, question].compactMap { $0 }.joined(separator: ": ")
            let detail = StatusTextCleaner.singleLine(needsYouEntry?.detail, maxLength: statusTextMaxLength)
            return (asked.isEmpty ? nil : asked) ?? detail ?? screenSignal ?? hookReason ?? "Waiting for your answer"
        case .working:
            return screenSignal ?? hookReason ?? "Working"
        case .needsYou, .parked, .ended:
            // Finished or idle with no prompt: the last screen line / recap.
            return screenSignal ?? hookReason ?? "Idle"
        }
    }
}
