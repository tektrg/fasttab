import Foundation

/// One entry from `GET /api/personas` — a named, long-lived agent whose home is a folder (see
/// `.claude/briefs/jev-persona-routing.md`). The dashboard owns the registry; AgentBar only reads
/// this shape and never writes into a folder itself.
struct Persona: Decodable, Equatable, Sendable {
    /// A per-persona default for what happens when it is picked with nothing running: resume the
    /// last conversation, or start fresh. Comes from the dashboard's `idleStart` field, added by a
    /// parallel P3 change — optional on the wire (decode as missing, not a decoding failure) until
    /// that ships everywhere; `effectiveIdleStart` is what callers should read instead of this
    /// field directly.
    enum IdleStart: String, Decodable, Sendable {
        case resume, fresh
    }

    let name: String
    let address: String
    let description: String
    let routesWhen: [String]
    let notFor: [String]
    /// Offline personas are never offered to Jev, and their sessions can't be reached (P2 scope:
    /// local host only — every persona today is `offline: false`).
    let offline: Bool
    /// The persona's front-door session's row id (same ids `/api/state` rows use), if one is
    /// live right now. Nil = nothing running for this persona.
    let mainRowId: String?
    /// Every other live session under this persona's folder, same row ids.
    let sessionRowIds: [String]
    let idleStart: IdleStart?
    /// The machine id this persona starts on by default (`"local"` or e.g. `"air-m1"`). Optional on
    /// the wire: a dashboard from before machine routing omits it (and `machines`), and the confirm
    /// row then shows no machine chips and sends no `machine`.
    var runsOn: String? = nil
    /// Every machine the persona may be started on, `"local"` first — the confirm row's chips.
    var machines: [PersonaMachine]? = nil

    /// `.fresh` when the dashboard hasn't started sending `idleStart` yet (see `IdleStart`'s doc
    /// comment) — never guess `.resume` for a field that simply isn't there.
    var effectiveIdleStart: IdleStart { idleStart ?? .fresh }
}

/// One `{id, label}` machine choice (`/api/personas` rows' `machines`, the registry's `machines`,
/// the start reply's `retryOn`). `id` is what the dashboard accepts; `label` ("Pro", "Air") is shown.
struct PersonaMachine: Codable, Equatable, Hashable, Sendable {
    let id: String
    let label: String
}
