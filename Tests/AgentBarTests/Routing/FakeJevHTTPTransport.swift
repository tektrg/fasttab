import Foundation
@testable import AgentBar

/// A Jev transport scripted per test; records every request so a test can also assert none
/// was made (the `candidates.isEmpty` no-network-call rule).
final class FakeJevHTTPTransport: JevHTTPTransport, @unchecked Sendable {
    enum Reply {
        case body(Data, statusCode: Int = 200)
        case error(Error)
    }

    struct ScriptedError: Error {}

    private let lock = NSLock()
    private var recordedRequests: [URLRequest] = []
    private let respond: @Sendable (URLRequest) -> Reply

    init(respond: @escaping @Sendable (URLRequest) -> Reply) {
        self.respond = respond
    }

    /// A single scripted reply, regardless of the request.
    convenience init(_ reply: Reply) {
        self.init { _ in reply }
    }

    var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return recordedRequests
    }

    var callCount: Int { requests.count }

    private func record(_ request: URLRequest) {
        lock.lock(); defer { lock.unlock() }
        recordedRequests.append(request)
    }

    func send(_ request: URLRequest) async throws -> (data: Data, statusCode: Int) {
        record(request)
        switch respond(request) {
        case .body(let data, let statusCode): return (data, statusCode)
        case .error(let error): throw error
        }
    }
}
