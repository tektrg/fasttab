import Foundation

/// The HTTP layer under `OpenRouterJevClient`. A protocol so tests can script OpenRouter's
/// reply without a network call. Deliberately its own (small, POST-a-request-get-a-reply)
/// seam rather than a reuse of `DashboardTransport`: that protocol's shape (a response method
/// plus an SSE `stream` method) and its name both belong to the dashboard's polling/streaming
/// status source, not to a single synchronous decision request to a different host.
protocol JevHTTPTransport: Sendable {
    /// Whole response. Throws on connection failure or timeout; a non-2xx status is
    /// returned, not thrown, so the caller can read the body OpenRouter put in it.
    func send(_ request: URLRequest) async throws -> (data: Data, statusCode: Int)
}

struct URLSessionJevHTTPTransport: JevHTTPTransport {
    private let session: URLSession

    init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    func send(_ request: URLRequest) async throws -> (data: Data, statusCode: Int) {
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
