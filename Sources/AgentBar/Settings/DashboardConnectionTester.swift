import Foundation

/// "Test connection": one read of the dashboard's state, reported in plain English.
struct DashboardConnectionTester: Sendable {
    enum Result: Equatable, Sendable {
        case connected(agentCount: Int)
        case failed(String)

        var message: String {
            switch self {
            case .connected(let count): "Connected — \(count) \(count == 1 ? "agent" : "agents")"
            case .failed(let reason): reason
            }
        }
    }

    let transport: DashboardTransport

    init(transport: DashboardTransport = URLSessionDashboardTransport()) {
        self.transport = transport
    }

    func test(_ baseURL: URL) async -> Result {
        let endpoint = DashboardEndpoint(baseURL: baseURL)
        let body: Data
        let statusCode: Int
        do {
            (body, statusCode) = try await transport.response(for: endpoint.stateRequest)
        } catch {
            return .failed("Can't reach \(endpoint.displayAddress). Is the dashboard running?")
        }
        guard (200..<300).contains(statusCode) else {
            return .failed("\(endpoint.displayAddress) answered with an error (HTTP \(statusCode)). Is that the chief dashboard?")
        }
        guard let payload = try? JSONDecoder().decode(DashboardPayload.self, from: body) else {
            return .failed("\(endpoint.displayAddress) answered, but not like the chief dashboard.")
        }
        return .connected(agentCount: payload.agents.count)
    }
}
