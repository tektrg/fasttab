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
