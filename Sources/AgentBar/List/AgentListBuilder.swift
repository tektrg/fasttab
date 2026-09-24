import Foundation
import CommandBarKit

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
        triage: TriageState = .empty
    ) -> AgentListPresentation {
        guard let snapshot else { return .connecting }

        if case .down(let reason) = snapshot.health {
            return AgentListPresentation(state: .feedDown(reason: reason), rows: [], showsBoardNote: false)
        }

        let note = !snapshot.boardIsCurrent
        let shown = shownAgents(in: snapshot, settings: settings, triage: triage)
        guard !shown.isEmpty else {
            return AgentListPresentation(state: .noAgents, rows: [], showsBoardNote: note)
        }

        let matching = agents(shown, matching: query)
        guard !matching.isEmpty else {
            return AgentListPresentation(state: .noMatches, rows: [], showsBoardNote: note)
        }

        return AgentListPresentation(
            state: .list,
            rows: rows(for: matching, tree: snapshot.agentTree, isSearching: !searchWords(in: query).isEmpty, frecency: frecency, now: now),
            showsBoardNote: note
        )
    }

    /// The agents the user can see before searching: parking and list settings applied.
    static func shownAgents(in snapshot: StatusSnapshot, settings: AgentListSettings, triage: TriageState) -> [AgentSnapshot] {
        settings.applying(to: triage.applying(to: snapshot.agents))
    }

    /// What is in the Needs you section, whatever the search says. Nil without a
    /// trustworthy reading (no snapshot yet, or the feed is down).
    static func needsYouAgents(snapshot: StatusSnapshot?, settings: AgentListSettings, triage: TriageState) -> [AgentSnapshot]? {
        guard let snapshot, !snapshot.health.isDown else { return nil }
        return shownAgents(in: snapshot, settings: settings, triage: triage).filter { $0.section == .needsYou }
    }

    /// Every query word must appear in the label, project, prompt excerpt or
    /// status text (accent- and case-insensitive). A blank query matches all.
    static func agents(_ agents: [AgentSnapshot], matching query: String) -> [AgentSnapshot] {
        let words = searchWords(in: query)
        guard !words.isEmpty else { return agents }
        return agents.filter { agent in
            let keys = [agent.label, agent.projectName, agent.promptExcerpt, agent.statusText]
                .compactMap { $0 }
                .map(foldForMatching)
            return foldedKeys(keys, containAllWordsOf: words)
        }
    }

    /// Needs you always flat and on top (unchanged). Below it: while searching, or before a
    /// non-empty tree has loaded, the old flat status sections (Working/Parked/Ended); otherwise
    /// the PO's "Nest under chief" grouping (`AgentListGrouping`) — one group per chief's project,
    /// then Unassigned.
    static func rows(for agents: [AgentSnapshot], tree: AgentTree?, isSearching: Bool, frecency: [String: FrecencyEntry], now: Date) -> [AgentListRow] {
        guard !isSearching, let tree, !tree.isEmpty else {
            return flatRows(for: agents, frecency: frecency, now: now)
        }
        let needsYou = agents.filter { $0.section == .needsYou }
        let rest = agents.filter { $0.section != .needsYou }
        var rows = needsYouRows(needsYou, frecency: frecency, now: now)
        rows.append(contentsOf: AgentListGrouping.rows(
            for: rest, tree: tree, needsYouIDs: Set(needsYou.map(\.id)), frecency: frecency, now: now
        ))
        return rows
    }

    /// Sections in display order, empty ones skipped, each behind its header. What every section
    /// looked like before the hierarchy grouping existed, and what a search still shows.
    private static func flatRows(for agents: [AgentSnapshot], frecency: [String: FrecencyEntry], now: Date) -> [AgentListRow] {
        AgentSection.allCases.flatMap { section -> [AgentListRow] in
            let inSection = agents.filter { $0.section == section }
            guard !inSection.isEmpty else { return [] }
            let ranked = AgentRanking.ordered(inSection, in: section, frecency: frecency, now: now)
            return [.header(section)] + ranked.map { .agent($0, nesting: .flat) }
        }
    }

    private static func needsYouRows(_ agents: [AgentSnapshot], frecency: [String: FrecencyEntry], now: Date) -> [AgentListRow] {
        guard !agents.isEmpty else { return [] }
        let ranked = AgentRanking.ordered(agents, in: .needsYou, frecency: frecency, now: now)
        return [.header(.needsYou)] + ranked.map { .agent($0, nesting: .flat) }
    }
}
