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
        let needsYouIndex = NeedsYouIndex(needsYou)
        let snapshots = agents.compactMap { snapshot(for: $0, needsYouIndex: needsYouIndex, board: board) }
        // Sections in display order; inside Needs you an agent with a real prompt
        // comes before one that merely finished; the server's order is kept otherwise.
        return snapshots.enumerated()
            .sorted { ($0.element.snapshot.section, $0.element.hasPrompt ? 0 : 1, $0.offset)
                < ($1.element.snapshot.section, $1.element.hasPrompt ? 0 : 1, $1.offset) }
            .map(\.element.snapshot)
    }

    /// The dashboard's question/blocked entries: herdr ones by pane, status-only (pane-less)
    /// ones by Claude session id.
    private struct NeedsYouIndex {
        var byPaneId: [String: DashboardNeedsYou] = [:]
        var bySessionId: [String: DashboardNeedsYou] = [:]

        init(_ entries: [DashboardNeedsYou]) {
            for entry in entries where entry.kind == "question" || entry.kind == "blocked" {
                if let paneId = nonEmpty(entry.paneId) {
                    if byPaneId[paneId] == nil { byPaneId[paneId] = entry }
                } else if let sessionId = nonEmpty(entry.agentSession), bySessionId[sessionId] == nil {
                    bySessionId[sessionId] = entry
                }
            }
        }

        func entry(paneId: String?, sessionId: String?) -> DashboardNeedsYou? {
            if let paneId { return byPaneId[paneId] }
            return sessionId.flatMap { bySessionId[$0] }
        }
    }

    private static func nonEmpty(_ text: String?) -> String? {
        text.flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func snapshot(
        for agent: DashboardAgent,
        needsYouIndex: NeedsYouIndex,
        board: BoardIndex
    ) -> (snapshot: AgentSnapshot, hasPrompt: Bool)? {
        // Residue = a leftover hook file whose pane is gone; nothing to switch to.
        guard agent.residue != true else { return nil }
        let paneId = nonEmpty(agent.paneId)
        let sessionId = nonEmpty(agent.agentSession)
        // A herdr row needs its pane; a status-only row (Claude Desktop / CLI) needs its session id,
        // which is its identity. An unknown `source` is kept only as a herdr pane.
        let host = AgentHost(source: agent.source, openUrl: agent.openUrl, tmuxTarget: agent.tmuxTarget)
            ?? (paneId == nil ? nil : .herdr)
        guard let host, let id = host.isHerdr ? paneId.map({ sessionId ?? $0 }) : sessionId else { return nil }
        let needsYouEntry = needsYouIndex.entry(paneId: host.isHerdr ? paneId : nil, sessionId: sessionId)
        let hasPrompt = AgentSectionClassifier.isAwaitingPrompt(
            screenState: agent.screenState, paneIsInDashboardNeedsYou: needsYouEntry != nil
        )
        let section = AgentSectionClassifier.section(
            hookState: agent.hookState,
            screenState: agent.screenState,
            paneIsInDashboardNeedsYou: needsYouEntry != nil
        )
        let pushText = board.unpushedText(rowId: agent.rowId, paneId: paneId)
        // A row in Needs you whose prompt the hook bridge holds (any host: a herdr pane scrolled away from
        // its picker included) answers through it; a herdr row without one keeps its screen path.
        let hookRequest = needsYouEntry == nil
            ? nil : HookRequest(needsYouEntry?.hookRequest) ?? HookRequest(agent.hookRequest)
        // No hook request: the question as read from the transcript, shown but not answerable here.
        let transcriptQuestion = host.isHerdr || needsYouEntry == nil || hookRequest != nil
            ? nil : needsYouEntry?.transcriptQuestion ?? agent.transcriptQuestion
        let askedHeader = hookRequest?.questions.first?.header ?? transcriptQuestion?.header
        let askedQuestion = hookRequest?.questions.first?.question ?? transcriptQuestion?.question
        let questionText = StatusTextCleaner.singleLine(
            agent.screenQuestion?.question ?? askedQuestion, maxLength: promptExcerptMaxLength
        )
        let screenSignal = StatusTextCleaner.singleLine(agent.screenSignal, maxLength: statusTextMaxLength)
        let snapshot = AgentSnapshot(
            id: id,
            label: agent.label ?? "",
            projectName: ProjectNameResolver.projectName(fromCwd: agent.cwd),
            cwd: agent.cwd,
            paneId: host.isHerdr ? paneId : nil,
            section: section,
            statusText: statusText(
                section: section, hasPrompt: hasPrompt, agent: agent, needsYouEntry: needsYouEntry,
                screenSignal: screenSignal, askedHeader: askedHeader, askedQuestion: askedQuestion
            ),
            secondsInStatus: needsYouEntry?.sinceSec ?? agent.hookSinceSec,
            hasUnpushedCommits: pushText != nil,
            unpushedText: pushText,
            promptExcerpt: questionText ?? StatusTextCleaner.singleLine(agent.screenSignal, maxLength: promptExcerptMaxLength),
            canFocus: true,
            hasHookData: agent.hasHookData ?? false,
            rowId: agent.rowId,
            sessionId: sessionId,
            // Status-only rows: the dashboard refuses stop/close on them; never offer Done.
            actions: host.isHerdr ? AgentActions(decoded: agent.actions, fallback: .unknown) : .none,
            // A hook request wins over the screen (Answer / Review work on it, no pane read). Without one a
            // herdr row uses its screen blocker; a status-only session is generic Needs you ("Input needed").
            blocker: hookRequest?.blocker ?? (host.isHerdr ? blocker(for: needsYouEntry) : nil),
            host: host,
            hookRequest: hookRequest,
            // A status-only session's needsYou entry = it is asking something: no message until answered.
            messagesViaInbox: !host.isHerdr && agent.messageVia == "inbox" && needsYouEntry == nil,
            messageTool: host.isHerdr ? Self.messageTool(forAgentKind: agent.agentKind) : nil,
            messageRefusal: agent.messageRefusal,
            awaitsPrompt: hasPrompt
        )
        return (snapshot, hasPrompt)
    }

    /// OpenCode and Codex rows are messaged as a plain prompt (see `MessageRoute.toolPane`); everything else is Claude.
    private static func messageTool(forAgentKind kind: String?) -> String? {
        guard let kind, kind == "opencode" || kind == "codex" else { return nil }
        return kind
    }

    /// A "question" row is answerable once its parsed picker has arrived (until
    /// then it is loading); a "blocked" row is a permission box (approvable once its parsed box has arrived) or an unconfirmed prompt.
    private static func blocker(for needsYouEntry: DashboardNeedsYou?) -> AgentBlocker? {
        switch needsYouEntry?.kind {
        case "question":
            if needsYouEntry?.question == nil { return .questionLoading(needsYouEntry?.questionPreview?.identity) }
            return AnswerableQuestion(needsYouEntry?.question).map(AgentBlocker.question) ?? .questionNotAnswerable
        case "blocked":
            return needsYouEntry?.permission?.prompt.map(AgentBlocker.permissionReview) ?? .permission
        default:
            return nil
        }
    }

    private static func statusText(
        section: AgentSection,
        hasPrompt: Bool,
        agent: DashboardAgent,
        needsYouEntry: DashboardNeedsYou?,
        screenSignal: String?,
        askedHeader: String?,
        askedQuestion: String?
    ) -> String {
        let hookReason = StatusTextCleaner.singleLine(agent.hookReason, maxLength: statusTextMaxLength)
        switch section {
        case .needsYou where hasPrompt:
            // The question (its title, then its text) is what is being asked. The dashboard's own
            // `detail` comes next: for a hook-preview question ("options loading")
            // it is fresher than the screen line, which is then stale. For a plain
            // permission prompt the screen line is the prompt itself (the hook
            // reason is only generic vendor copy) — same precedence as the dashboard.
            let title = StatusTextCleaner.singleLine(agent.screenQuestion?.title ?? askedHeader, maxLength: statusTextMaxLength)
            let question = StatusTextCleaner.singleLine(agent.screenQuestion?.question ?? askedQuestion, maxLength: statusTextMaxLength)
            let asked = [title, question].compactMap { $0 }.joined(separator: ": ")
            let detail = StatusTextCleaner.singleLine(needsYouEntry?.detail, maxLength: statusTextMaxLength)
            return (asked.isEmpty ? nil : asked) ?? detail ?? screenSignal ?? hookReason ?? "Waiting for your answer"
        case .working:
            return screenSignal ?? hookReason ?? "Working"
        case .needsYou, .parked, .ended, .sleeping:
            // Finished or idle with no prompt: the last screen line / recap.
            return screenSignal ?? hookReason ?? "Idle"
        }
    }
}
