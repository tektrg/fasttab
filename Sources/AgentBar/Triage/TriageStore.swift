import Foundation

/// Persists `TriageState` in AgentBar's UserDefaults domain, so parked agents
/// stay parked across launches.
struct TriageStore {
    static let defaultsKey = "parkedAgentIDs"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Unreadable data is treated as "nothing parked": an agent showing up in
    /// Needs you again is harmless, crashing on it is not.
    func load() -> TriageState {
        guard let ids = defaults.stringArray(forKey: Self.defaultsKey) else { return .empty }
        return TriageState(parkedIDs: Set(ids))
    }

    func save(_ state: TriageState) {
        defaults.set(state.parkedIDs.sorted(), forKey: Self.defaultsKey)
    }
}
