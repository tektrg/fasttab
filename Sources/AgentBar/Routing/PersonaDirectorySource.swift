import Foundation

/// What `POST /api/persona/start` returned.
enum PersonaStartOutcome: Equatable, Sendable {
    case started(paneId: String)
    case resumed(paneId: String)
    /// Covers a `{ok: false, error}` reply, a reply AgentBar couldn't decode, and a network/
    /// timeout failure alike — the confirm-row spec draws no distinction between them ("never
    /// auto-retry a start" either way), so callers just show `reason`.
    case failed(String)
}

/// The dashboard's persona registry, as `AgentPanelModel` needs it — `DashboardStatusSource`
/// conforms; tests fake it. Both calls are best-effort from the caller's point of view: routing
/// falls back to sessions-only when `fetchPersonas` returns `nil`, exactly as if the dashboard had
/// no personas at all.
protocol PersonaDirectorySource: Sendable {
    /// `GET /api/personas`. Nil on any failure — unreachable dashboard, timeout, non-2xx status,
    /// or an undecodable reply — never partial results.
    func fetchPersonas() async -> [Persona]?

    /// `POST /api/persona/start`. `fresh: true` only for an explicit "start new"; otherwise the
    /// dashboard applies the persona's own `idleStart` default.
    func startPersona(_ name: String, text: String, fresh: Bool) async -> PersonaStartOutcome
}
