import Foundation

/// "How long in this status" for a row, ticking between refreshes.
enum AgentAge {
    /// Seconds in status as of `now`: the server's figure at fetch time plus
    /// the time since we fetched. Nil when the server did not say.
    static func seconds(for agent: AgentSnapshot, fetchedAt: Date, now: Date) -> TimeInterval? {
        agent.secondsInStatus.map { $0 + max(0, now.timeIntervalSince(fetchedAt)) }
    }

    /// Coarse, one unit: "<1m", "4m", "2h", "3d".
    static func shortText(_ seconds: TimeInterval) -> String {
        let whole = Int(max(0, seconds))
        switch whole {
        case ..<60: return "<1m"
        case ..<3_600: return "\(whole / 60)m"
        case ..<86_400: return "\(whole / 3_600)h"
        default: return "\(whole / 86_400)d"
        }
    }
}
