import Foundation

/// What a brand-new AptusFit worker got, once `POST /api/worker` succeeded.
struct WorkerCreationResult: Equatable, Sendable {
    let paneId: String
    let worktreePath: String
    let branch: String
}

/// Outcome of asking the dashboard to start a brand-new AptusFit worker. Never retried by any
/// caller — a slow reply may still have landed, exactly like every other dashboard write.
enum WorkerCreationOutcome: Equatable, Sendable {
    case created(WorkerCreationResult)
    /// Refused or unreachable, in the dashboard's own words when it gave any.
    case failed(String)
}

/// A separate, narrow capability from `AgentStatusSource` (mirrors `RoutingAPIKeyStoring`'s own
/// separate-protocol-plus-property precedent): starting a new worker is not about an existing
/// agent's pane/row at all, so it stays out of the pane-centric protocol every status-source fake
/// in the test suite already conforms to, rather than adding a default no-op there.
protocol DashboardWorkerCreating: Sendable {
    /// Starts a brand-new worker in `repoAlias`'s AptusFit repo, on a fresh worktree/branch named
    /// after `slug`, with `task` delivered as its brief and launch prompt by the dashboard itself.
    func createWorker(repoAlias: String, slug: String, task: String) async -> WorkerCreationOutcome
}

/// `POST /api/worker` reply: `{"ok": true, "paneId": "...", "worktreePath": "...", "branch": "..."}`
/// or `{"ok": false, "error": "..."}` — see AptusFit's `chief_dashboard_worker.create_worker()`.
struct DashboardWorkerResponse: Decodable {
    let ok: Bool?
    let paneId: String?
    let worktreePath: String?
    let branch: String?
    let error: String?

    /// The outcome the reply amounts to; a `true` reply missing any of the three fields it
    /// promises reads as a failure, never as a partial success.
    var outcome: WorkerCreationOutcome {
        if ok == true, let paneId, let worktreePath, let branch {
            return .created(WorkerCreationResult(paneId: paneId, worktreePath: worktreePath, branch: branch))
        }
        return .failed(error ?? "The dashboard refused to create the worker.")
    }
}
