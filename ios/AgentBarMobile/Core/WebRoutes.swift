import Foundation

/// URL rules for the web-view wrapper around the AgentBar PWA.
/// Mirrors dashboard/ui/public/sw.js `safeOpenPath`: a push may only open a same-origin path.
public enum WebRoutes {
    public static let loginPath = "/remote/login"
    public static let sessionCookieName = "agentbar_remote_session"

    /// `path` when it is a same-origin path ("/..." but not "//..." or "/\..."), else nil.
    public static func safePath(_ path: Any?) -> String? {
        guard let p = path as? String, p.hasPrefix("/"), !p.hasPrefix("//"), !p.hasPrefix("/\\"),
              !p.contains(where: { $0.isNewline }) else { return nil }
        return p
    }

    /// base + safe path; the base itself when the path is unsafe or missing.
    public static func url(base: URL, path: Any?) -> URL {
        guard let p = safePath(path), let url = URL(string: base.absoluteString + p),
              isSameOrigin(url, base: base) else { return base }
        return url
    }

    /// Same scheme, host and effective port.
    public static func isSameOrigin(_ url: URL, base: URL) -> Bool {
        guard let s = url.scheme?.lowercased(), s == base.scheme?.lowercased(),
              let h = url.host?.lowercased(), h == base.host?.lowercased() else { return false }
        return effectivePort(url) == effectivePort(base)
    }

    /// Same check for a WebKit security origin (protocol/host/port; port 0 = default).
    public static func isSameOrigin(scheme: String, host: String, port: Int, base: URL) -> Bool {
        var c = URLComponents(); c.scheme = scheme; c.host = host; c.port = port == 0 ? nil : port
        guard let url = c.url else { return false }
        return isSameOrigin(url, base: base)
    }

    /// True for the PWA's login page on this origin (where an expired session lands).
    public static func isLoginPage(_ url: URL, base: URL) -> Bool {
        isSameOrigin(url, base: base) && url.path == loginPath
    }

    /// The session cookie from a /remote/login response, if the server issued one.
    public static func sessionCookie(headers: [AnyHashable: Any], url: URL) -> HTTPCookie? {
        let fields = headers.reduce(into: [String: String]()) { out, kv in
            if let k = kv.key as? String, let v = kv.value as? String { out[k] = v }
        }
        return HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
            .first { $0.name == sessionCookieName && !$0.value.isEmpty }
    }

    private static func effectivePort(_ url: URL) -> Int {
        url.port ?? (url.scheme?.lowercased() == "http" ? 80 : 443)
    }
}

extension AgentBarAPI {
    /// POST /remote/login {"token"}: the server answers 302 + Set-Cookie on success,
    /// 200 + login page on a bad token. No Origin header (login is exempt from the CSRF check).
    public func loginRequest() -> URLRequest {
        var request = URLRequest(url: URL(string: baseURL.absoluteString + WebRoutes.loginPath)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["token": token])
        return request
    }
}
