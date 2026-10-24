import Foundation

/// What the user decided on a permission prompt.
public enum PermissionAnswer: Equatable {
    case allow
    /// Deny, optionally with guidance text for the agent (REPLY = deny + message).
    case deny(message: String?)

    /// Maps a notification action id (+ typed text for REPLY) to an answer.
    /// nil for unknown actions (e.g. the default tap).
    public init?(actionIdentifier: String, replyText: String?) {
        switch actionIdentifier {
        case AgentBarPush.Action.allow: self = .allow
        case AgentBarPush.Action.deny: self = .deny(message: nil)
        case AgentBarPush.Action.reply:
            let text = replyText?.trimmingCharacters(in: .whitespacesAndNewlines)
            self = .deny(message: (text?.isEmpty ?? true) ? nil : text)
        default: return nil
        }
    }

    var body: [String: String] {
        switch self {
        case .allow: return ["behavior": "allow"]
        case .deny(let message?): return ["behavior": "deny", "message": message]
        case .deny(nil): return ["behavior": "deny"]
        }
    }
}

/// Builds authenticated requests to the dashboard's remote listener.
public struct AgentBarAPI {
    public enum ConfigError: Error, Equatable { case invalidBaseURL }

    public let baseURL: URL
    public let token: String

    /// Accepts "host.ts.net", "https://host.ts.net/" etc.; https is forced
    /// unless an explicit http:// scheme is given.
    public init(baseURLString: String, token: String) throws {
        var raw = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        while raw.hasSuffix("/") { raw.removeLast() }
        if !raw.contains("://") { raw = "https://" + raw }
        guard let url = URL(string: raw), let scheme = url.scheme, ["https", "http"].contains(scheme),
              let host = url.host, !host.isEmpty else { throw ConfigError.invalidBaseURL }
        self.baseURL = url
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func answerRequest(requestId: String, answer: PermissionAnswer) -> URLRequest {
        let escaped = requestId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? requestId
        return jsonRequest(path: "/api/hook/permission/\(escaped)/answer", method: "POST", body: answer.body)
    }

    public func registerDeviceRequest(deviceToken: String, label: String?) -> URLRequest {
        var body = ["deviceToken": deviceToken]
        if let label, !label.isEmpty { body["label"] = label }
        return jsonRequest(path: "/api/apns/devices", method: "POST", body: body)
    }

    public func unregisterDeviceRequest(deviceToken: String) -> URLRequest {
        jsonRequest(path: "/api/apns/devices", method: "DELETE", body: ["deviceToken": deviceToken])
    }

    private func jsonRequest(path: String, method: String, body: [String: String]) -> URLRequest {
        var request = URLRequest(url: URL(string: baseURL.absoluteString + path)!)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }
}

public enum DeviceTokenHex {
    /// APNs device token bytes -> lowercase hex (what the server stores).
    public static func encode(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
