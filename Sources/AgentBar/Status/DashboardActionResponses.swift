import Foundation

/// `POST /api/focus` reply: `{"ok": true}` or `{"ok": false, "error": "..."}`.
struct DashboardFocusResponse: Decodable {
    let ok: Bool?
    let error: String?
}

/// `GET /api/pane/screen` reply: `{"ok": true, "lines": [...], "readTs": <epoch secs>}`
/// or `{"ok": false, "error": "...", "readTs": ...}`.
struct DashboardPaneScreenResponse: Decodable {
    let ok: Bool?
    let lines: [String]?
    let readTs: Double?
    let error: String?
}

/// `POST /api/session/{stop,close}` reply: `{"ok": true, "state": "...", "reason": "..."}`,
/// `{"ok": false, "needsConfirm": true, "reason": "..."}` (nothing was done) or
/// `{"ok": false, "error": "..."}`.
struct DashboardSessionActionResponse: Decodable {
    let ok: Bool?
    let needsConfirm: Bool?
    let reason: String?
    let error: String?

    /// The outcome the reply amounts to; nil when it says nothing usable.
    var outcome: SessionActionOutcome? {
        if ok == true { return .succeeded }
        if needsConfirm == true { return .needsConfirmation(reason: reason ?? "") }
        return error.map(SessionActionOutcome.failed)
    }
}

/// `POST /api/answer` reply: `{"ok": true, "next": <parsed question or null>}`
/// or `{"ok": false, "error": "..."}` (the picker was not touched, or the answer
/// may not have landed: the reason says which).
struct DashboardAnswerResponse: Decodable {
    let ok: Bool?
    let error: String?
    let next: DashboardQuestion?

    /// The result the reply amounts to; nil when it says nothing usable.
    var result: AnswerResult? {
        switch ok {
        case true?: .sent(next: AnswerableQuestion(next))
        case false?: .failed(error ?? "The dashboard refused the answer.")
        case nil: nil
        }
    }
}

/// How the dashboard answered a permission request.
enum PermissionResult: Equatable, Sendable {
    /// The key landed. `next` is a different permission box open in the pane afterwards, if any.
    case sent(next: PermissionPrompt?)
    /// Refused or unreachable, in the dashboard's own words when it gave any. Nothing is retried.
    case failed(String)
    /// This dashboard has no such endpoint (it predates it, or needs a restart): the reply, in words.
    case unsupported(String)
}

/// `POST /api/permission` reply: `{"ok": true, "next": <permission or null>}` or
/// `{"ok": false, "error": "..."}`. A dashboard that predates the endpoint answers 404 or 405
/// (typically `{"error": "not found"}`).
struct DashboardPermissionResponse: Decodable {
    let ok: Bool?
    let error: String?
    let next: DashboardPermission?

    /// The result a reply amounts to. HTTP 404 / 405 mean the endpoint is missing, whatever the body says.
    static func result(body: Data, statusCode: Int) -> PermissionResult {
        let reply = try? JSONDecoder().decode(DashboardPermissionResponse.self, from: body)
        if statusCode == 404 || statusCode == 405 {
            return .unsupported(reply?.error ?? "HTTP \(statusCode)")
        }
        switch reply?.ok {
        case true?: return .sent(next: reply?.next?.prompt)
        case false?: return .failed(reply?.error ?? "The dashboard refused the decision.")
        case nil: return .failed(reply?.error ?? "The dashboard sent an unreadable reply. Check the agent's terminal.")
        }
    }
}
