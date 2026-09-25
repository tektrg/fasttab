import Foundation

/// The dashboard's URLs and the request shapes AgentBar sends it.
struct DashboardEndpoint: Sendable {
    static let defaultBaseURL = URL(string: "http://127.0.0.1:4711")!
    /// UserDefaults key (in AgentBar's own defaults domain) overriding the base URL.
    static let baseURLDefaultsKey = "dashboardBaseURL"

    /// Peek reads this many trailing screen lines (server clamps to 1...400).
    /// (100 is what the dashboard itself reads before it decides on a permission box or question.)
    static let paneScreenLineCount = 100
    /// The server's own read of a wedged pane gives up at 15s; wait a bit longer.
    static let paneScreenTimeoutSeconds: TimeInterval = 20
    static let requestTimeoutSeconds: TimeInterval = 10
    /// Stop gives the agent's processes a grace period before killing them.
    static let sessionActionTimeoutSeconds: TimeInterval = 30
    /// An answer types into the pane, then re-reads it several times (up to a
    /// minute for a multi-select with a review step) before it replies.
    static let answerTimeoutSeconds: TimeInterval = 90
    /// A permission press is one key, then a re-read of the pane (a few seconds).
    static let permissionTimeoutSeconds: TimeInterval = 45
    /// A message types into the pane and re-reads it to see whether it was submitted (2s or more).
    static let messageTimeoutSeconds: TimeInterval = 60
    /// Attach/detach are one write to the dashboard's own tree state, no pane involved: a plain
    /// request-timeout budget is generous.
    static let agentTreeActionTimeoutSeconds: TimeInterval = 20
    /// A short budget on purpose: this runs inline with a Jev route call every time routing
    /// starts, so a slow or dead dashboard must not delay that — `fetchPersonas` treats a timeout
    /// the same as "no personas" and falls back to sessions only.
    static let personasTimeoutSeconds: TimeInterval = 5
    /// `herdr tab create` + launching Claude "may take a few seconds" per the brief.
    static let personaStartTimeoutSeconds: TimeInterval = 30
    /// The dashboard's accident guard: only the product owner's clicks may stop
    /// or close (`PO_ACTOR` in chief_dashboard_actions.py). AgentBar acts only
    /// on the user's own click, so it speaks as that actor.
    static let sessionActionActor = "po"

    let baseURL: URL

    /// The configured URL, or the default when unset or not an http(s) URL.
    /// Pass `.standard` in the app: that is the `com.trungluong.AgentBar` domain.
    static func configured(defaults: UserDefaults = .standard) -> DashboardEndpoint {
        guard let text = defaults.string(forKey: baseURLDefaultsKey),
              case .valid(let url) = DashboardAddress.validate(text) else {
            return DashboardEndpoint(baseURL: defaultBaseURL)
        }
        return DashboardEndpoint(baseURL: url)
    }

    /// "host:port" for messages, e.g. "127.0.0.1:4711".
    var displayAddress: String {
        let host = baseURL.host ?? baseURL.absoluteString
        return baseURL.port.map { "\(host):\($0)" } ?? host
    }

    var stateRequest: URLRequest { request(path: "/api/state") }

    /// The stream is idle-timed by URLSession: the dashboard pushes every ~2s,
    /// so `requestTimeoutSeconds` of silence means it is wedged and we reconnect.
    var eventsRequest: URLRequest {
        var request = request(path: "/api/events")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        return request
    }

    func focusRequest(paneId: String) -> URLRequest {
        var request = request(path: "/api/focus")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["paneId": paneId])
        return request
    }

    /// `POST /api/answer`. `question` goes back exactly as the dashboard sent it:
    /// it refuses unless the pane still shows that very question.
    func answerRequest(paneId: String, choice: AnswerChoice, question: QuestionIdentity) -> URLRequest {
        var request = request(path: "/api/answer")
        request.httpMethod = "POST"
        request.timeoutInterval = Self.answerTimeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "paneId": paneId,
            "choice": choice.jsonObject,
            "question": ["title": question.title, "question": question.question],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// `POST /api/permission`. `permission` goes back as the pane was read: the dashboard
    /// presses nothing unless the box still equals it.
    func permissionRequest(paneId: String, choice: PermissionChoice, permission: PermissionPrompt) -> URLRequest {
        permissionPost(["paneId": paneId, "choice": choice.wireName, "permission": Self.permissionBox(permission)])
    }

    /// `POST /api/permission` with `choice: "select"` for a plan-approval box: `index` is the 1-based row,
    /// `text` (only for the feedback row) what to type. `permission` goes back as read, option labels
    /// included: the dashboard compares them with the box it reads itself before pressing the one key.
    func planSelectRequest(paneId: String, index: Int, text: String?, permission: PermissionPrompt) -> URLRequest {
        var body: [String: Any] = ["paneId": paneId, "choice": "select", "index": index, "permission": Self.permissionBox(permission)]
        if let text { body["text"] = text }
        return permissionPost(body)
    }

    private func permissionPost(_ body: [String: Any]) -> URLRequest {
        var request = request(path: "/api/permission")
        request.httpMethod = "POST"
        request.timeoutInterval = Self.permissionTimeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// The box as the dashboard's own parser shapes it. A plan box has `detail: null` and `kind` / `planPath`
    /// (null when its footer is absent): the dashboard's exact-match check compares each of them.
    private static func permissionBox(_ permission: PermissionPrompt) -> [String: Any] {
        var box: [String: Any] = [
            "tool": permission.tool,
            "detail": permission.isPlan ? NSNull() : permission.detail,
            "title": permission.title,
            "options": permission.options.map { ["index": $0.index, "label": $0.label] as [String: Any] },
        ]
        if let cursorIndex = permission.cursorIndex { box["cursorIndex"] = cursorIndex }
        if permission.isPlan {
            box["kind"] = "plan"
            box["planPath"] = permission.planPath ?? NSNull()
        }
        return box
    }

    /// `POST /api/session/stop|close`. `confirmed` is sent only when the user
    /// pressed the confirm step, and only then (absent means "not confirmed").
    func sessionActionRequest(_ kind: SessionActionKind, rowId: String, confirmed: Bool) -> URLRequest {
        var request = request(path: "/api/session/\(kind.rawValue)")
        request.httpMethod = "POST"
        request.timeoutInterval = Self.sessionActionTimeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["rowId": rowId, "actor": Self.sessionActionActor]
        if confirmed { body["confirm"] = true }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// `POST /api/session/message`. `text` is already sanitized (one line, no leading "/").
    /// `confirmed` is sent only for the second press after the dashboard said the agent is mid-turn.
    func messageRequest(rowId: String, text: String, confirmed: Bool) -> URLRequest {
        var request = request(path: "/api/session/message")
        request.httpMethod = "POST"
        request.timeoutInterval = Self.messageTimeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["rowId": rowId, "actor": Self.sessionActionActor, "text": text]
        if confirmed { body["confirm"] = true }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// `POST /api/agent-tree/attach`: `child` reports to the chief `parent`. `confirmCrossProject`
    /// is sent only on the retry after a `needsConfirm` (409) reply.
    func agentTreeAttachRequest(child: String, parent: String, confirmCrossProject: Bool) -> URLRequest {
        var request = request(path: "/api/agent-tree/attach")
        request.httpMethod = "POST"
        request.timeoutInterval = Self.agentTreeActionTimeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "child": child, "parent": parent, "confirmCrossProject": confirmCrossProject,
        ])
        return request
    }

    /// `POST /api/agent-tree/detach`: `child` reports nowhere until attached again.
    func agentTreeDetachRequest(child: String) -> URLRequest {
        var request = request(path: "/api/agent-tree/detach")
        request.httpMethod = "POST"
        request.timeoutInterval = Self.agentTreeActionTimeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["child": child])
        return request
    }

    /// `GET /api/personas`.
    var personasRequest: URLRequest {
        var request = request(path: "/api/personas")
        request.timeoutInterval = Self.personasTimeoutSeconds
        return request
    }

    /// `POST /api/persona/start`. `fresh` is sent only when `true`, so the dashboard applies the
    /// persona's own `idleStart` default whenever the caller didn't force a new session.
    func personaStartRequest(persona: String, text: String, fresh: Bool) -> URLRequest {
        var request = request(path: "/api/persona/start")
        request.httpMethod = "POST"
        request.timeoutInterval = Self.personaStartTimeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["persona": persona, "text": text]
        if fresh { body["fresh"] = true }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    func paneScreenRequest(paneId: String) -> URLRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/pane/screen"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "paneId", value: paneId),
            URLQueryItem(name: "lines", value: String(Self.paneScreenLineCount)),
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = Self.paneScreenTimeoutSeconds
        return request
    }

    private func request(path: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.timeoutInterval = Self.requestTimeoutSeconds
        return request
    }
}
