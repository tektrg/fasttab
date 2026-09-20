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

/// `POST /api/session/{stop,close,message}` reply: `{"ok": true, "state": "...", "reason": "..."}`,
/// `{"ok": false, "needsConfirm": true, "reason": "..."}` (nothing was done) or
/// `{"ok": false, "error": "..."}`.
struct DashboardSessionActionResponse: Decodable {
    let ok: Bool?
    let needsConfirm: Bool?
    let reason: String?
    let error: String?
    /// What the dashboard did, e.g. "stopped (3 procs)"; for a message "queued" or "message sent".
    let state: String?

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
    /// `warning` is the dashboard's own words when the send went through but the pane ended up somewhere
    /// unexpected (a plan `select` that left the pane in auto mode): always shown to the user, never dropped.
    case sent(next: PermissionPrompt?, warning: String? = nil)
    /// Refused or unreachable, in the dashboard's own words when it gave any. Nothing is retried.
    case failed(String)
    /// This dashboard has no such endpoint (it predates it, or needs a restart): the reply, in words.
    case unsupported(String)
}

/// `POST /api/permission` reply: `{"ok": true, "next": <permission or null>, "warning": "..."?}` or
/// `{"ok": false, "error": "..."}`. `warning` (optional) rides on an ok reply only. A dashboard that
/// predates the endpoint answers 404 or 405 (typically `{"error": "not found"}`).
struct DashboardPermissionResponse: Decodable {
    let ok: Bool?
    let error: String?
    let next: DashboardPermission?
    /// Trimmed; nil when absent, null or blank. A warning that is not a string still counts as one
    /// (`unreadableWarning`): the key was pressed, so a strange value must never read as "all fine".
    let warning: String?

    static let unreadableWarning = "the dashboard sent a warning AgentBar could not read"

    private enum CodingKeys: String, CodingKey { case ok, error, next, warning }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decodeIfPresent(Bool.self, forKey: .ok)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        next = try container.decodeIfPresent(DashboardPermission.self, forKey: .next)
        if let text = try? container.decodeIfPresent(String.self, forKey: .warning) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            warning = trimmed.isEmpty ? nil : trimmed
        } else if (try? container.decodeNil(forKey: .warning)) == false {
            warning = Self.unreadableWarning
        } else {
            warning = nil
        }
    }

    /// The result a reply amounts to. HTTP 404 / 405 mean the endpoint is missing, whatever the body says.
    static func result(body: Data, statusCode: Int) -> PermissionResult {
        let reply = try? JSONDecoder().decode(DashboardPermissionResponse.self, from: body)
        if statusCode == 404 || statusCode == 405 {
            return .unsupported(reply?.error ?? "HTTP \(statusCode)")
        }
        switch reply?.ok {
        case true?: return .sent(next: reply?.next?.prompt, warning: reply?.warning)
        case false?: return .failed(reply?.error ?? "The dashboard refused the decision.")
        case nil: return .failed(reply?.error ?? "The dashboard sent an unreadable reply. Check the agent's terminal.")
        }
    }
}
