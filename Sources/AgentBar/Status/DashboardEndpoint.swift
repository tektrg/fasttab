import Foundation

/// The dashboard's URLs and the request shapes AgentBar sends it.
struct DashboardEndpoint: Sendable {
    static let defaultBaseURL = URL(string: "http://127.0.0.1:4711")!
    /// UserDefaults key (in AgentBar's own defaults domain) overriding the base URL.
    static let baseURLDefaultsKey = "dashboardBaseURL"

    /// Peek reads this many trailing screen lines (server clamps to 1...400).
    static let paneScreenLineCount = 80
    /// The server's own read of a wedged pane gives up at 15s; wait a bit longer.
    static let paneScreenTimeoutSeconds: TimeInterval = 20
    static let requestTimeoutSeconds: TimeInterval = 10
    /// Stop gives the agent's processes a grace period before killing them.
    static let sessionActionTimeoutSeconds: TimeInterval = 30
    /// An answer types into the pane, then re-reads it several times (up to a
    /// minute for a multi-select with a review step) before it replies.
    static let answerTimeoutSeconds: TimeInterval = 90
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
