import Foundation

/// The HTTP layer under `DashboardStatusSource`. A protocol so tests can script
/// the dashboard without a network.
protocol DashboardTransport: Sendable {
    /// Whole response. Throws on connection failure; a non-2xx status is
    /// returned, not thrown, because the dashboard puts JSON errors in 400s.
    func response(for request: URLRequest) async throws -> (body: Data, statusCode: Int)

    /// Body chunks as they arrive. Throws on connection failure, idle timeout
    /// or a non-2xx status; finishes normally when the server closes the stream.
    func stream(for request: URLRequest) -> AsyncThrowingStream<Data, Error>
}

struct UnexpectedHTTPStatus: Error, Equatable {
    let statusCode: Int
}

struct URLSessionDashboardTransport: DashboardTransport {
    private let session: URLSession

    init(session: URLSession = URLSessionDashboardTransport.makeSession()) {
        self.session = session
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    func response(for request: URLRequest) async throws -> (body: Data, statusCode: Int) {
        let (body, response) = try await session.data(for: request)
        return (body, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    func stream(for request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let reader = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
                        throw UnexpectedHTTPStatus(statusCode: status)
                    }
                    // Hand over one line at a time: cheap, and never splits an event mid-line.
                    var line = Data()
                    for try await byte in bytes {
                        line.append(byte)
                        if byte == UInt8(ascii: "\n") {
                            continuation.yield(line)
                            line.removeAll(keepingCapacity: true)
                        }
                    }
                    if !line.isEmpty { continuation.yield(line) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in reader.cancel() }
        }
    }
}
