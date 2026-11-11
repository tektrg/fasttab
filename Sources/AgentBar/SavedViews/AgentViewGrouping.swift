import Foundation
import IndieCommandBar
import IndieSavedViews

/// Rows for a saved view's agents by its group-by. Pure. `.none` is the All page's own layout.
enum AgentViewGrouping {
    static let noProjectTitle = "No project"

    static func rows(
        for agents: [AgentSnapshot],
        groupBy: AgentViewGroupBy,
        tree: AgentTree?,
        isSearching: Bool,
        frecency: [String: FrecencyEntry],
        now: Date,
        calendar: Calendar = .current
    ) -> [AgentListRow] {
        switch groupBy {
        case .none:
            return AgentListBuilder.rows(for: agents, tree: tree, isSearching: isSearching, frecency: frecency, now: now)
        case .status:
            return AgentListBuilder.flatRows(for: agents, frecency: frecency, now: now)
        case .project:
            var byProject: [String: [AgentSnapshot]] = [:]
            var noProject: [AgentSnapshot] = []
            for agent in agents {
                if let project = agent.projectName, !project.isEmpty {
                    byProject[project, default: []].append(agent)
                } else {
                    noProject.append(agent)
                }
            }
            let names = byProject.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            var rows: [AgentListRow] = []
            for name in names {
                rows.append(.groupHeader(key: "project-\(name)", title: name))
                rows += ranked(byProject[name] ?? [], frecency: frecency, now: now).map { .agent($0, nesting: .flat) }
            }
            if !noProject.isEmpty {
                rows.append(.groupHeader(key: "project-none", title: noProjectTitle))
                rows += ranked(noProject, frecency: frecency, now: now).map { .agent($0, nesting: .flat) }
            }
            return rows
        case .lastActive:
            let groups = DayBucket.group(agents, now: now, calendar: calendar) { agent in
                agent.activitySeconds.map { now.addingTimeInterval(-$0) }
            }
            return groups.flatMap { group in
                [.groupHeader(key: "day-\(group.bucket.rawValue)", title: group.bucket.title)]
                    + group.items.sorted { ($0.activitySeconds ?? .infinity) < ($1.activitySeconds ?? .infinity) }
                        .map { .agent($0, nesting: .flat) }
            }
        }
    }

    /// Status order first, then each status's own ranking.
    private static func ranked(_ agents: [AgentSnapshot], frecency: [String: FrecencyEntry], now: Date) -> [AgentSnapshot] {
        AgentSection.allCases.flatMap { section in
            AgentRanking.ordered(agents.filter { $0.section == section }, in: section, frecency: frecency, now: now)
        }
    }
}
