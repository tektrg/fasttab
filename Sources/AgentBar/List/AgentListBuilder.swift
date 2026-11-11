import Foundation
import IndieCommandBar
import IndieSearch

/// Turns the latest status snapshot into the list the panel shows: state
/// selection, parking (`TriageState`), the user's list settings, search
/// filtering, section grouping and ranking. Pure.
enum AgentListBuilder {
    static func presentation(
        snapshot: StatusSnapshot?,
        query: String,
        frecency: [String: FrecencyEntry],
        now: Date,
        settings: AgentListSettings = .standard,
        triage: TriageState = .empty,
        view: AgentSavedView? = nil
    ) -> AgentListPresentation {
        guard let snapshot else { return .connecting }

        if case .down(let reason) = snapshot.health {
            return AgentListPresentation(state: .feedDown(reason: reason), rows: [], showsBoardNote: false)
        }

        let note = !snapshot.boardIsCurrent
        if NewWorkerMode.isEntryCommand(query) {
            return AgentListPresentation(state: .newWorkerCommand, rows: [], showsBoardNote: note)
        }
        let isSearching = isSearchQuery(query)
        let shown = shownAgents(in: snapshot, settings: settings, triage: triage, isSearching: isSearching)
        guard !shown.isEmpty else {
            return AgentListPresentation(state: .noAgents, rows: [], showsBoardNote: note)
        }

        // A saved view (nil = the All page, today's list exactly): its own filter and grouping.
        if let view {
            let matching = agents(view.filter(shown), matching: query)
            guard !matching.isEmpty else {
                return AgentListPresentation(state: .noMatches, rows: [], showsBoardNote: note)
            }
            let rows = AgentViewGrouping.rows(
                for: matching, groupBy: view.groupBy, tree: snapshot.agentTree,
                isSearching: isSearching, frecency: frecency, now: now
            )
            return AgentListPresentation(state: .list, rows: rows, showsBoardNote: note)
        }

        let matching = agents(shown, matching: query)
        guard !matching.isEmpty else {
            return AgentListPresentation(state: .noMatches, rows: [], showsBoardNote: note)
        }

        return AgentListPresentation(
            state: .list,
            rows: rows(for: matching, tree: snapshot.agentTree, isSearching: isSearching, frecency: frecency, now: now),
            showsBoardNote: note
        )
    }

    /// The agents the user can see: parking and list settings applied. Searching also brings in
    /// older sleeping sessions (`AgentListSettings.sleepingSearchDays`).
    static func shownAgents(
        in snapshot: StatusSnapshot, settings: AgentListSettings, triage: TriageState, isSearching: Bool = false
    ) -> [AgentSnapshot] {
        settings.applying(to: triage.applying(to: snapshot.agents), isSearching: isSearching)
    }

    /// What is in the Needs you section, whatever the search says. Nil without a
    /// trustworthy reading (no snapshot yet, or the feed is down).
    static func needsYouAgents(snapshot: StatusSnapshot?, settings: AgentListSettings, triage: TriageState) -> [AgentSnapshot]? {
        guard let snapshot, !snapshot.health.isDown else { return nil }
        return shownAgents(in: snapshot, settings: settings, triage: triage).filter { $0.section == .needsYou }
    }

    /// A query that filters: any words, or a `*wildcard*` / `/regex/` (`TextPattern`).
    static func isSearchQuery(_ query: String) -> Bool {
        TextPattern.isPattern(query.trimmingCharacters(in: .whitespacesAndNewlines)) || !searchWords(in: query).isEmpty
    }

    /// A blank query matches all. A whole-query `*wildcard*` or `/regex/` (`TextPattern`) must
    /// match the label, project, folder, prompt excerpt or status text; otherwise every query word
    /// must appear in one of them (accent- and case-insensitive).
    /// A sleeping row's status text is only its age ("Sleeping · 2d ago"), so just "Sleeping"
    /// is searched: otherwise "ag" (…agentbar) or "d" would match every sleeping session via "ago".
    static func agents(_ agents: [AgentSnapshot], matching query: String) -> [AgentSnapshot] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if TextPattern.isPattern(trimmed) {
            // A broken regex normalizes to nil: no entries, matches nothing.
            let pattern = TextPattern.Compiled(TextPattern.normalize(trimmed).map { [$0] } ?? [])
            return agents.filter { pattern.matches(anyOf: searchTexts(of: $0)) }
        }
        let words = searchWords(in: query)
        guard !words.isEmpty else { return agents }
        return agents.filter { agent in
            foldedKeys(searchTexts(of: agent).compactMap { $0 }.map(foldForMatching), containAllWordsOf: words)
        }
    }

    private static func searchTexts(of agent: AgentSnapshot) -> [String?] {
        let statusKey = agent.section == .sleeping ? SleepingSessionMapper.statusPrefix : agent.statusText
        return [agent.label, agent.projectName, agent.cwd, agent.promptExcerpt, statusKey]
    }

    /// While searching, or before a non-empty tree has loaded: the old flat status sections
    /// (Needs you/Working/Parked/Ended). Otherwise the PO's "Nest inside each section" grouping
    /// (`AgentListGrouping`) — same sections, same order, same ranking, with each section's workers
    /// nested under their chief's anchor row.
    static func rows(for agents: [AgentSnapshot], tree: AgentTree?, isSearching: Bool, frecency: [String: FrecencyEntry], now: Date) -> [AgentListRow] {
        guard !isSearching, let tree, !tree.isEmpty else {
            return flatRows(for: agents, frecency: frecency, now: now)
        }
        return AgentListGrouping.rows(for: agents, tree: tree, frecency: frecency, now: now)
    }

    /// Sections in display order, empty ones skipped, each behind its header. What every section
    /// looked like before the hierarchy grouping existed, and what a search still shows.
    static func flatRows(for agents: [AgentSnapshot], frecency: [String: FrecencyEntry], now: Date) -> [AgentListRow] {
        AgentSection.allCases.flatMap { section -> [AgentListRow] in
            let inSection = agents.filter { $0.section == section }
            guard !inSection.isEmpty else { return [] }
            let ranked = AgentRanking.ordered(inSection, in: section, frecency: frecency, now: now)
            return [.header(section)] + ranked.map { .agent($0, nesting: .flat) }
        }
    }
}
