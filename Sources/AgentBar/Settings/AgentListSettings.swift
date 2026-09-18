import Foundation

/// The user's choices about what the list shows. Pure value: `load`/`save`
/// move it in and out of UserDefaults, `applying(to:)` narrows a snapshot's
/// agents. Anything stored that is not one of the offered choices falls back
/// to that setting's default.
struct AgentListSettings: Equatable, Sendable {
    static let endedWindowHoursChoices = [1, 6, 24, 72]
    static let maxEndedRowsChoices = [0, 4, 8, 16]
    static let maxVisibleRowsRange = 6...16

    static let endedWindowHoursKey = "listEndedWindowHours"
    static let maxEndedRowsKey = "listMaxEndedRows"
    static let showsNonClaudePanesKey = "listShowsNonClaudePanes"
    static let maxVisibleRowsKey = "listMaxVisibleRows"

    /// Defaults are the previously hard-coded behaviour.
    static let standard = AgentListSettings(
        endedWindowHours: Int(EndedAgentMapper.endedWindowSeconds / 3_600),
        maxEndedRows: EndedAgentMapper.maxEndedCount,
        showsNonClaudePanes: true,
        maxVisibleRows: AgentPanelMetrics.defaultMaxVisibleRows
    )

    var endedWindowHours: Int
    var maxEndedRows: Int
    /// Plain shells and other CLIs (OpenCode): panes with no Claude hook data.
    var showsNonClaudePanes: Bool
    /// Rows shown before the list scrolls.
    var maxVisibleRows: Int

    var endedWindowSeconds: TimeInterval { TimeInterval(endedWindowHours) * 3_600 }

    static func load(from defaults: UserDefaults) -> AgentListSettings {
        let standard = Self.standard
        return AgentListSettings(
            endedWindowHours: choice(defaults, endedWindowHoursKey, in: endedWindowHoursChoices, fallback: standard.endedWindowHours),
            maxEndedRows: choice(defaults, maxEndedRowsKey, in: maxEndedRowsChoices, fallback: standard.maxEndedRows),
            showsNonClaudePanes: defaults.object(forKey: showsNonClaudePanesKey) as? Bool ?? standard.showsNonClaudePanes,
            maxVisibleRows: choice(defaults, maxVisibleRowsKey, in: Array(maxVisibleRowsRange), fallback: standard.maxVisibleRows)
        )
    }

    func save(to defaults: UserDefaults) {
        defaults.set(endedWindowHours, forKey: Self.endedWindowHoursKey)
        defaults.set(maxEndedRows, forKey: Self.maxEndedRowsKey)
        defaults.set(showsNonClaudePanes, forKey: Self.showsNonClaudePanesKey)
        defaults.set(maxVisibleRows, forKey: Self.maxVisibleRowsKey)
    }

    /// The agents that pass these settings, order kept. Ended rows arrive newest
    /// first, so the cap keeps the newest.
    func applying(to agents: [AgentSnapshot]) -> [AgentSnapshot] {
        var endedKept = 0
        return agents.filter { agent in
            if !showsNonClaudePanes && !agent.hasHookData { return false }
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
