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
        let shown = settings.applying(to: triage.applying(to: snapshot.agents))
        guard !shown.isEmpty else {
            return AgentListPresentation(state: .noAgents, rows: [], showsBoardNote: note)
        }

        let matching = agents(shown, matching: query)
        guard !matching.isEmpty else {
            return AgentListPresentation(state: .noMatches, rows: [], showsBoardNote: note)
        }

        return AgentListPresentation(
            state: .list,
            rows: rows(for: matching, frecency: frecency, now: now),
            showsBoardNote: note
        )
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

    /// Sections in display order, empty ones skipped, each behind its header.
    static func rows(for agents: [AgentSnapshot], frecency: [String: FrecencyEntry], now: Date) -> [AgentListRow] {
        AgentSection.allCases.flatMap { section -> [AgentListRow] in
            let inSection = agents.filter { $0.section == section }
            guard !inSection.isEmpty else { return [] }
            let ranked = AgentRanking.ordered(inSection, in: section, frecency: frecency, now: now)
            return [.header(section)] + ranked.map(AgentListRow.agent)
        }
    }
}
