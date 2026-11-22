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

/// `GET /api/session/latest` reply: `{"ok": true, "latestMessage": "..."|null, "pendingQuestion": {...}|null, ...}`
/// or `{"ok": false, "error": "..."}`.
struct DashboardSessionLatestResponse: Decodable {
    let ok: Bool?
    let latestMessage: String?
    /// Nil when absent, null or unreadable: an odd form never costs the message.
    let pendingQuestion: PendingQuestionForm?

    private enum CodingKeys: String, CodingKey { case ok, latestMessage, pendingQuestion }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decodeIfPresent(Bool.self, forKey: .ok)
        latestMessage = try container.decodeIfPresent(String.self, forKey: .latestMessage)
        pendingQuestion = (try? container.decodeIfPresent(DashboardPendingQuestion.self, forKey: .pendingQuestion))?.form
    }
}

/// `pendingQuestion` of `GET /api/session/latest`: the dashboard's port of `AskUserQuestionExtractor`
/// (`session_transcript._build_form`): `{toolUseId, questions[{question, header, isMultiSelect, options[{label, description}]}]}`.
/// `header`, `isMultiSelect` and `description` may be missing; a question without text or options, or an option
/// without a label, makes the whole form unreadable (the transcript reader drops such a call too).
struct DashboardPendingQuestion: Decodable {
    struct Question: Decodable {
        let question: String
        let header: String?
        let isMultiSelect: Bool?
        let options: [Option]
    }

    struct Option: Decodable {
        let label: String
        let description: String?
    }

    let toolUseId: String
    let questions: [Question]

    var form: PendingQuestionForm? {
        guard !toolUseId.isEmpty, !questions.isEmpty else { return nil }
        let readable = questions.allSatisfy { question in
            !question.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !question.options.isEmpty && question.options.allSatisfy { !$0.label.isEmpty }
        }
        guard readable else { return nil }
        return PendingQuestionForm(toolUseId: toolUseId, questions: questions.map { question in
            FormQuestion(
                header: question.header ?? "", question: question.question, isMultiSelect: question.isMultiSelect ?? false,
                options: question.options.map { FormQuestion.Option(label: $0.label, description: $0.description ?? "") }
            )
        })
    }
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

/// `/api/session/compact` replies (contract `.claude/compact-api-contract.md`): `{"ok": true, "job": Job|null}`,
/// `{"ok": false, "error": "job-active", "job": Job}` (409) or `{"ok": false, "error": "<reason>"}`.
/// A `job` that is present but unreadable is kept apart from a null one: it must never read as "no job".
struct DashboardCompactResponse: Decodable {
    let ok: Bool?
    let error: String?
    let job: CompactJob?
    let jobUnreadable: Bool

    static let activeError = "job-active"
    static let missingEndpointReason = "This dashboard can't compact yet (restart it)."

    private enum CodingKeys: String, CodingKey { case ok, error, job }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = container.lenient(.ok)
        error = container.lenient(.error)
        let jobIsNull = !container.contains(.job) || ((try? container.decodeNil(forKey: .job)) ?? false)
        job = jobIsNull ? nil : (try? container.decode(CompactJob.self, forKey: .job))
        jobUnreadable = !jobIsNull && job == nil
    }

    /// What a `POST` reply amounts to. A 2xx without a readable job is `.uncertain`: something may have started.
    static func startOutcome(body: Data, statusCode: Int) -> CompactStartOutcome {
        let reply = try? JSONDecoder().decode(DashboardCompactResponse.self, from: body)
        if let job = reply?.job {
            if statusCode == 409 || reply?.error == activeError { return .alreadyRunning(job) }
            if reply?.ok == true { return .started(job) }
        }
        if (200..<300).contains(statusCode) {
            return .uncertain("The dashboard's reply was unreadable. The compact may have started.")
        }
        // An older dashboard has no such route: its generic 404 is not a reason worth showing.
        if statusCode == 404 || statusCode == 405, reply?.ok != false || reply?.error == "not found" {
            return .failed(missingEndpointReason)
        }
        return .failed(reply?.error ?? "The dashboard refused the compact (HTTP \(statusCode)).")
    }

    /// What a `GET` reply amounts to. 404 = no such job (or a dashboard without compact jobs).
    static func read(body: Data, statusCode: Int) -> CompactJobRead {
        if statusCode == 404 { return .none }
        let reply = try? JSONDecoder().decode(DashboardCompactResponse.self, from: body)
        guard (200..<300).contains(statusCode), let reply, reply.ok == true, !reply.jobUnreadable else {
            return .failed(reply?.error ?? "The dashboard sent an unreadable reply (HTTP \(statusCode)).")
        }
        return reply.job.map(CompactJobRead.job) ?? .none
    }
}
