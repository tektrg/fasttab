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

    let baseURL: URL

    /// The configured URL, or the default when unset or not an http(s) URL.
    /// Pass `.standard` in the app: that is the `com.trungluong.AgentBar` domain.
    static func configured(defaults: UserDefaults = .standard) -> DashboardEndpoint {
        guard let text = defaults.string(forKey: baseURLDefaultsKey),
              let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host != nil else {
            return DashboardEndpoint(baseURL: defaultBaseURL)
        }
        return DashboardEndpoint(baseURL: url)
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
