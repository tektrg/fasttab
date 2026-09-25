import Foundation

/// The AptusFit sub-areas `POST /api/worker` can start a brand-new worker in — the app-side mirror
/// of AptusFit's `scripts/lib/chief_dashboard_worker.py` `REPO_ALIAS_CANON` (canonical value only,
/// not every accepted synonym) and `scripts/session-worktree.sh`'s `resolve_repo()` (repo path,
/// quoted in `summary` below). That file's own docstring already says the canon table is "kept in
/// sync by hand" with `resolve_repo()`; this is one more link in that same chain, not a fourth
/// source of truth — re-copy this list if either changes. v1 is intentionally scoped to AptusFit's
/// own sub-areas (confirmed 2026-09-22), never a generic "any repo" worktree creator.
enum WorkerArea: String, CaseIterable, Equatable, Sendable {
    case fe, backend, landing, meta, skills

    /// The `"new:"`-namespaced id this area is offered to Jev under, and echoed back verbatim.
    /// Namespaced apart from live-agent ids (plain pane ids) so the two can never collide.
    static let candidateIDPrefix = "new:"

    /// `repoAlias` sent to `POST /api/worker` — the canonical value `REPO_ALIAS_CANON` resolves
    /// every accepted synonym to, not merely one synonym among several.
    var repoAlias: String { rawValue }

    var candidateID: String { Self.candidateIDPrefix + rawValue }

    /// Short human label for the confirm UI and success/failure notices.
    var label: String {
        switch self {
        case .fe: "AptusFit frontend"
        case .backend: "AptusFit backend"
        case .landing: "AptusFit landing/marketing site"
        case .meta: "AptusFit meta/harness workspace"
        case .skills: "AptusFit agent skills"
        }
    }

    /// One line for Jev's `criteria`, so it can tell "start a NEW worker here" apart from routing
    /// to any of the live agents in the same choice. The repo path in each is `resolve_repo()`'s,
    /// not guessed.
    var summary: String {
        switch self {
        case .fe: "Start a NEW AptusFit worker (fresh worktree + session) in the frontend/mobile app repo (path \"fe\"), not an existing agent"
        case .backend: "Start a NEW AptusFit worker (fresh worktree + session) in the backend repo (path \"aptusfit-backend\"), not an existing agent"
        case .landing: "Start a NEW AptusFit worker (fresh worktree + session) in the landing/marketing site repo (path \"landing\"), not an existing agent"
        case .meta: "Start a NEW AptusFit worker (fresh worktree + session) in the meta/harness workspace root (path \".\") — cross-cutting tooling, not a product area; not an existing agent"
        case .skills: "Start a NEW AptusFit worker (fresh worktree + session) in the agent skills repo (path \"fe/.agents/skills\"), not an existing agent"
        }
    }

    /// `candidateID` -> the area it names, or nil for a live-agent id (a plain pane id never
    /// starts with the "new:" prefix).
    static func from(candidateID: String) -> WorkerArea? {
        guard candidateID.hasPrefix(candidateIDPrefix) else { return nil }
        return WorkerArea(rawValue: String(candidateID.dropFirst(candidateIDPrefix.count)))
    }
}
