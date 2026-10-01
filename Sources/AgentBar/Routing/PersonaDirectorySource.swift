import Foundation

/// What `POST /api/persona/start` returned.
enum PersonaStartOutcome: Equatable, Sendable {
    case started(paneId: String)
    case resumed(paneId: String)
    /// Covers a `{ok: false, error}` reply, a reply AgentBar couldn't decode, and a network/
    /// timeout failure alike — the confirm-row spec draws no distinction between them ("never
    /// auto-retry a start" either way), so callers just show `reason`.
    case failed(String)
    /// The target machine couldn't be reached (`{ok:false, unreachable:true, retryOn}`) — nothing
    /// was started. `retryOn` is the dashboard's suggested other machine, offered on the confirm
    /// row for one more Return; nil when it named none (then it reads like `.failed`).
    case unreachable(reason: String, retryOn: PersonaMachine?)
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
    /// dashboard applies the persona's own `idleStart` default. `machine` (a machine id) overrides
    /// the persona's `runsOn` for this one start; nil sends none.
    func startPersona(_ name: String, text: String, fresh: Bool, machine: String?) async -> PersonaStartOutcome
}
