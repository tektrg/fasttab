import Foundation
@testable import AgentBar

/// A dashboard transport scripted per test, recording every request it sees.
final class ScriptedDashboardTransport: DashboardTransport, @unchecked Sendable {
    enum Reply {
        case body(Data, statusCode: Int = 200)
        case fail
    }

    struct ScriptedError: Error {}

    private let lock = NSLock()
    private var recordedRequests: [URLRequest] = []
    private let respond: @Sendable (URLRequest) -> Reply
    private let streamChunks: [Data]?
    private let streamEndsWithError: Bool

    /// `streamChunks == nil` makes the SSE connection fail outright.
    init(streamChunks: [Data]? = nil, streamEndsWithError: Bool = false, respond: @escaping @Sendable (URLRequest) -> Reply) {
        self.streamChunks = streamChunks
        self.streamEndsWithError = streamEndsWithError
        self.respond = respond
    }

    var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return recordedRequests
    }

    private func record(_ request: URLRequest) {
        lock.lock(); defer { lock.unlock() }
        recordedRequests.append(request)
    }

    func response(for request: URLRequest) async throws -> (body: Data, statusCode: Int) {
        record(request)
        switch respond(request) {
        case .body(let data, let statusCode): return (data, statusCode)
        case .fail: throw ScriptedError()
        }
    }

    func stream(for request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        record(request)
        let chunks = streamChunks
        let endsWithError = streamEndsWithError
        return AsyncThrowingStream { continuation in
            guard let chunks else {
                continuation.finish(throwing: ScriptedError())
                return
            }
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish(throwing: endsWithError ? ScriptedError() : nil)
        }
    }
}

/// Collects a source's updates in the background so tests can wait for them.
final class SnapshotCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [StatusSnapshot] = []
    private var task: Task<Void, Never>?

    init(_ updates: AsyncStream<StatusSnapshot>) {
        task = Task { [weak self] in
            for await snapshot in updates { self?.append(snapshot) }
        }
    }

    deinit { task?.cancel() }

    var snapshots: [StatusSnapshot] {
        lock.lock(); defer { lock.unlock() }
        return collected
    }

    private func append(_ snapshot: StatusSnapshot) {
        lock.lock(); defer { lock.unlock() }
        collected.append(snapshot)
    }

    /// Waits until `condition` holds for the snapshots so far; false on timeout.
    func wait(timeoutSeconds: Double = 5, until condition: @Sendable ([StatusSnapshot]) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if condition(snapshots) { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition(snapshots)
    }
}
