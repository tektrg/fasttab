import AgentBarCore
import WebKit

/// Signs the web view in with the Keychain token, so the user never types it into the PWA.
/// Posts the token to /remote/login natively (exactly what the PWA's login form does),
/// takes the HttpOnly session cookie from the 302, and puts it in the web view's cookie store.
enum RemoteSession {
    enum Failure: Error { case notConfigured, tokenRejected, unreachable(Error) }

    static func signIn(api: AgentBarAPI, into store: WKHTTPCookieStore,
                       completion: @escaping (Result<Void, Failure>) -> Void) {
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirects.shared, delegateQueue: nil)
        session.dataTask(with: api.loginRequest()) { _, response, error in
            session.finishTasksAndInvalidate()
            DispatchQueue.main.async {
                if let error { return completion(.failure(.unreachable(error))) }
                guard let http = response as? HTTPURLResponse, let url = http.url,
                      let cookie = WebRoutes.sessionCookie(headers: http.allHeaderFields, url: url)
                else { return completion(.failure(.tokenRejected)) }
                store.setCookie(cookie) { completion(.success(())) }
            }
        }.resume()
    }

    /// Keep the 302 so its Set-Cookie can be read (following it would drop the header).
    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        static let shared = NoRedirects()
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
