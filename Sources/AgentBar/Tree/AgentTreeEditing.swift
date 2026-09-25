import Foundation

/// Outcome of `POST /api/agent-tree/attach`.
enum AttachOutcome: Equatable, Sendable {
    /// The key landed. `warning` rides on an ok reply when the dashboard did something the caller
    /// should know about even though it succeeded (mirrors `PermissionResult.sent(next:warning:)`).
    case attached(warning: String?)
    /// 409: the child and the chosen chief are in different projects. Retry with
    /// `confirmCrossProject: true` to go ahead, in the server's own words.
    case needsConfirm(message: String)
    /// 400: cycle / two-level / unknown-agent / self, in the server's own words.
    case refused(message: String)
    /// Unreachable, unreadable reply, or any other failure. Never retried automatically — a slow
    /// reply may still have landed, same rule as every other dashboard write.
    case failed(String)
}

/// Outcome of `POST /api/agent-tree/detach`.
enum DetachOutcome: Equatable, Sendable {
    case detached
    case failed(String)
}

/// A separate, narrow capability from `AgentStatusSource`: editing who-reports-to-whom isn't about
/// one existing agent's pane/row, so it stays out of the pane-centric protocol every status-source
/// fake already conforms to.
protocol AgentTreeEditing: Sendable {
    /// Attaches `child` to report to the chief `parent`. `confirmCrossProject` is sent only on the
    /// retry after a `.needsConfirm` reply (mirrors `confirmed` on `perform`/`sendMessage`).
    func attachToTree(child: String, parent: String, confirmCrossProject: Bool) async -> AttachOutcome
    /// Detaches `child`: it reports nowhere (Unassigned) until attached again.
    func detachFromTree(child: String) async -> DetachOutcome
}

/// `POST /api/agent-tree/attach` reply. Success: `{"ok":true,"warning":str|null}`. Needs
/// confirmation (HTTP 409): `{"error":"cross-project","needsConfirm":true,"message":str}`. Refused
/// (HTTP 400): `{"error":"cycle"|"two-level"|"unknown-agent"|"self","message":str}`.
struct DashboardAttachResponse: Decodable {
    let ok: Bool?
    let warning: String?
    let error: String?
    let needsConfirm: Bool?
    let message: String?

    /// The outcome this reply amounts to. Branches on the fields themselves, not `statusCode`: the
    /// three shapes above never overlap (only one of `ok` / `needsConfirm` / `error` is ever set).
    var outcome: AttachOutcome {
        if ok == true { return .attached(warning: warning) }
        if needsConfirm == true { return .needsConfirm(message: message ?? "This attaches across two different projects. Attach anyway?") }
        if error != nil { return .refused(message: message ?? error ?? "The dashboard refused that attach.") }
        return .failed("The dashboard sent an unreadable reply.")
    }
}

/// `POST /api/agent-tree/detach` reply: `{"ok":true}` or `{"ok":false,"error":"..."}` (uses the
/// same session-action shape as the other endpoints, so it reuses that response type — see
/// `DashboardActionResponses.swift`).
struct DashboardDetachResponse: Decodable {
    let ok: Bool?
    let error: String?

    var outcome: DetachOutcome {
        ok == true ? .detached : .failed(error ?? "The dashboard refused to detach that agent.")
    }
}
