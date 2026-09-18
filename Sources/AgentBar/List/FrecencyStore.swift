import Foundation
import CommandBarKit

/// The user's own switches, persisted as JSON in AgentBar's UserDefaults
/// domain and keyed by agent id (session id, else pane id).
struct FrecencyStore {
    static let defaultsKey = "agentFrecency"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Stored entries minus stale ones. Unreadable data is treated as empty:
    /// losing ranking history is harmless, crashing on it is not.
    func load(now: Date = Date()) -> [String: FrecencyEntry] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let entries = try? JSONDecoder().decode([String: FrecencyEntry].self, from: data)
        else { return [:] }
        return entries.filter { !Frecency.shouldEvict($0.value, now: now) }
    }

    func save(_ entries: [String: FrecencyEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    /// `entries` with one more visit to `agentID`; stale entries dropped.
    static func recordingVisit(
        to agentID: String,
        in entries: [String: FrecencyEntry],
        now: Date = Date()
    ) -> [String: FrecencyEntry] {
        var updated = entries.filter { !Frecency.shouldEvict($0.value, now: now) }
        if var existing = updated[agentID] {
            Frecency.applyVisit(&existing, now: now)
            updated[agentID] = existing
        } else {
            updated[agentID] = Frecency.newEntry(now: now)
        }
        return updated
    }
}
