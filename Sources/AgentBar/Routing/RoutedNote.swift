import Foundation

/// One routed message the row is still holding: what Shift+Return routing sent it. Only the
/// user clears it (✕) — it never expires on its own.
struct RoutedNote: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let text: String
    let sentAt: Date
}

/// Persists routed notes per agent id in AgentBar's own `UserDefaults` domain, newest first.
/// Mirrors `TriageStore`'s shape.
struct RoutedNoteStore {
    static let defaultsKey = "routedNotesByAgentID"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Unreadable data reads as "no notes": a row missing a note it once had is harmless,
    /// crashing on it is not.
    func load() -> [String: [RoutedNote]] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([String: [RoutedNote]].self, from: data)
        else { return [:] }
        return decoded
    }

    func save(_ notes: [String: [RoutedNote]]) {
        guard let data = try? JSONEncoder().encode(notes) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
