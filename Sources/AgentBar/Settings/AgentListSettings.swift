import Foundation

/// The user's choices about what the list shows. Pure value: `load`/`save`
/// move it in and out of UserDefaults, `applying(to:)` narrows a snapshot's
/// agents. Anything stored that is not one of the offered choices falls back
/// to that setting's default.
struct AgentListSettings: Equatable, Sendable {
    static let endedWindowHoursChoices = [1, 6, 24, 72]
    static let maxEndedRowsChoices = [0, 4, 8, 16]
    static let maxVisibleRowsRange = 6...16
    /// Days a sleeping Claude Desktop session stays listed; 0 = only found by search. The largest
    /// choice is the dashboard's own window (`desktop_sessions.SLEEPING_WINDOW_DAYS`, 14).
    static let sleepingListDaysChoices = [0, 1, 2, 3, 5, 7, 14]
    static let sleepingSearchDaysChoices = [1, 2, 3, 5, 7, 14]

    static let endedWindowHoursKey = "listEndedWindowHours"
    static let maxEndedRowsKey = "listMaxEndedRows"
    static let showsNonClaudePanesKey = "listShowsNonClaudePanes"
    static let showsClaudeOutsideHerdrKey = "listShowsClaudeOutsideHerdr"
    static let maxVisibleRowsKey = "listMaxVisibleRows"
    static let sleepingListDaysKey = "listSleepingListDays"
    static let sleepingSearchDaysKey = "listSleepingSearchDays"

    /// Defaults are the previously hard-coded behaviour.
    static let standard = AgentListSettings(
        endedWindowHours: Int(EndedAgentMapper.endedWindowSeconds / 3_600),
        maxEndedRows: EndedAgentMapper.maxEndedCount,
        showsNonClaudePanes: true,
        showsClaudeOutsideHerdr: true,
        maxVisibleRows: AgentPanelMetrics.defaultMaxVisibleRows
    )

    var endedWindowHours: Int
    var maxEndedRows: Int
    /// Plain shells and other CLIs (OpenCode): panes with no Claude hook data.
    var showsNonClaudePanes: Bool
    /// Status-only Claude sessions outside herdr (Claude Desktop, CLI in tmux): `AgentHost`.
    var showsClaudeOutsideHerdr: Bool
    /// Rows shown before the list scrolls.
    var maxVisibleRows: Int
    /// Sleeping Claude Desktop sessions (`AgentSection.sleeping`) last active within this many days
    /// are listed; while searching, `sleepingSearchDays` (or this, if larger) applies instead.
    /// Defaults 3 / 7 days: PO call 2026-09-27.
    var sleepingListDays: Int = 3
    var sleepingSearchDays: Int = 7

    var endedWindowSeconds: TimeInterval { TimeInterval(endedWindowHours) * 3_600 }

    /// How recently a sleeping session must have been active to show.
    func sleepingWindowSeconds(isSearching: Bool) -> TimeInterval {
        TimeInterval(isSearching ? max(sleepingListDays, sleepingSearchDays) : sleepingListDays) * 86_400
    }

    static func load(from defaults: UserDefaults) -> AgentListSettings {
        let standard = Self.standard
        return AgentListSettings(
            endedWindowHours: choice(defaults, endedWindowHoursKey, in: endedWindowHoursChoices, fallback: standard.endedWindowHours),
            maxEndedRows: choice(defaults, maxEndedRowsKey, in: maxEndedRowsChoices, fallback: standard.maxEndedRows),
            showsNonClaudePanes: defaults.object(forKey: showsNonClaudePanesKey) as? Bool ?? standard.showsNonClaudePanes,
            showsClaudeOutsideHerdr: defaults.object(forKey: showsClaudeOutsideHerdrKey) as? Bool ?? standard.showsClaudeOutsideHerdr,
            maxVisibleRows: choice(defaults, maxVisibleRowsKey, in: Array(maxVisibleRowsRange), fallback: standard.maxVisibleRows),
            sleepingListDays: choice(defaults, sleepingListDaysKey, in: sleepingListDaysChoices, fallback: standard.sleepingListDays),
            sleepingSearchDays: choice(defaults, sleepingSearchDaysKey, in: sleepingSearchDaysChoices, fallback: standard.sleepingSearchDays)
        )
    }

    func save(to defaults: UserDefaults) {
        defaults.set(endedWindowHours, forKey: Self.endedWindowHoursKey)
        defaults.set(maxEndedRows, forKey: Self.maxEndedRowsKey)
        defaults.set(showsNonClaudePanes, forKey: Self.showsNonClaudePanesKey)
        defaults.set(showsClaudeOutsideHerdr, forKey: Self.showsClaudeOutsideHerdrKey)
        defaults.set(maxVisibleRows, forKey: Self.maxVisibleRowsKey)
        defaults.set(sleepingListDays, forKey: Self.sleepingListDaysKey)
        defaults.set(sleepingSearchDays, forKey: Self.sleepingSearchDaysKey)
    }

    /// The agents that pass these settings, order kept. Ended rows arrive newest
    /// first, so the cap keeps the newest. `isSearching` widens the sleeping-session window.
    func applying(to agents: [AgentSnapshot], isSearching: Bool = false) -> [AgentSnapshot] {
        var endedKept = 0
        let sleepingWindow = sleepingWindowSeconds(isSearching: isSearching)
        return agents.filter { agent in
            if !showsNonClaudePanes && !agent.hasHookData { return false }
            if !showsClaudeOutsideHerdr && !agent.host.isHerdr { return false }
            if agent.section == .sleeping { return (agent.secondsInStatus ?? .infinity) <= sleepingWindow }
            guard agent.section == .ended else { return true }
            guard (agent.secondsInStatus ?? 0) <= endedWindowSeconds, endedKept < maxEndedRows else { return false }
            endedKept += 1
            return true
        }
    }

    private static func choice(_ defaults: UserDefaults, _ key: String, in choices: [Int], fallback: Int) -> Int {
        guard let stored = defaults.object(forKey: key) as? Int, choices.contains(stored) else { return fallback }
        return stored
    }
}
