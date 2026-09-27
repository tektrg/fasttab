import Foundation

/// Settings > Personas' dashboard calls. Every failure becomes one plain-English sentence; a 404
/// means the dashboard predates these endpoints, which gets its own "update it" wording instead of
/// a bare "not found".
struct PersonaRegistryClient: Sendable {
    static let timeoutSeconds: TimeInterval = 10
    static let dashboardTooOldMessage =
        "This dashboard is too old for persona settings — update it (pull this repo and restart the dashboard)."

    let baseURL: URL
    let transport: DashboardTransport

    init(baseURL: URL, transport: DashboardTransport = URLSessionDashboardTransport()) {
        self.baseURL = baseURL
        self.transport = transport
    }

    func loadRegistry() async -> Result<PersonaRegistry, PersonaRegistryFailure> {
        await decode(PersonaRegistry.self, from: request(path: "/api/personas/registry"))
    }

    func loadSuggestions() async -> Result<[PersonaSuggestion], PersonaRegistryFailure> {
        await decode([PersonaSuggestion].self, from: request(path: "/api/personas/suggestions"))
    }

    /// The updated registry on success; the dashboard's own refusal text otherwise.
    func apply(_ action: PersonaRegistryAction) async -> Result<PersonaRegistry, PersonaRegistryFailure> {
        var request = request(path: "/api/personas")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: action.body)
        return await decode(PostReply.self, from: request).flatMap { reply in
            if reply.ok == true, let registry = reply.registry { return .success(registry) }
            return .failure(PersonaRegistryFailure(reply.error ?? "The dashboard refused the change."))
        }
    }

    // MARK: - Plumbing

    private struct PostReply: Decodable {
        let ok: Bool?
        let error: String?
        let registry: PersonaRegistry?
    }

    private struct ErrorReply: Decodable {
        let error: String?
    }

    private var displayAddress: String { DashboardEndpoint(baseURL: baseURL).displayAddress }

    private func request(path: String) -> URLRequest {
        var request = DashboardEndpoint.agentBarRequest(url: baseURL.appendingPathComponent(path))
        request.timeoutInterval = Self.timeoutSeconds
        return request
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from request: URLRequest) async
        -> Result<Value, PersonaRegistryFailure> {
        let body: Data
        let statusCode: Int
        do {
            (body, statusCode) = try await transport.response(for: request)
        } catch {
            return .failure(PersonaRegistryFailure("Can't reach the dashboard at \(displayAddress). Is it running?"))
        }
        if statusCode == 404 { return .failure(PersonaRegistryFailure(Self.dashboardTooOldMessage)) }
        guard (200..<300).contains(statusCode) else {
            let reason = (try? JSONDecoder().decode(ErrorReply.self, from: body))?.error
            return .failure(PersonaRegistryFailure(reason ?? "The dashboard answered with an error (HTTP \(statusCode))."))
        }
        guard let value = try? JSONDecoder().decode(Value.self, from: body) else {
            return .failure(PersonaRegistryFailure(
                "The dashboard sent a reply AgentBar can't read. It may be a different version — update it."))
        }
        return .success(value)
    }
}

/// A user-facing reason, shown verbatim.
struct PersonaRegistryFailure: Error, Equatable, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
}
