import Foundation
import IndieSharing

/// A device of the signed-in user as the server lists it (only what the web reader needs).
public struct WebReaderDevice: Equatable, Sendable, Identifiable {
    public var id: String
    public var platform: String
    public var app: String
    public var name: String?
    public var publicKey: String
    public var createdAt: Date?
    public var lastSeenAt: Date?

    public init(id: String, platform: String, app: String, name: String? = nil, publicKey: String,
                createdAt: Date? = nil, lastSeenAt: Date? = nil) {
        self.id = id.lowercased()
        self.platform = platform
        self.app = app
        self.name = name
        self.publicKey = publicKey
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
    }

    public var isWebBrowser: Bool { platform == "web" }
}

/// One pending item of the highlights/progress inbox (`GET /v1/snapshots/fasttab/highlights`).
public struct WebInboxItem: Codable, Equatable, Sendable {
    public var id: String
    public var articleId: String
    public var suite: String
    public var wraps: [WebKeyWrap]
    /// base64url ciphertext.
    public var ciphertext: String

    public init(id: String, articleId: String, suite: String, wraps: [WebKeyWrap], ciphertext: String) {
        self.id = id
        self.articleId = articleId
        self.suite = suite
        self.wraps = wraps
        self.ciphertext = ciphertext
    }
}

public struct WebInboxPage: Codable, Equatable, Sendable {
    public var items: [WebInboxItem]
    /// Pass back as `after` for the next page; nil = no more.
    public var cursor: String?

    public init(items: [WebInboxItem], cursor: String?) {
        self.items = items
        self.cursor = cursor
    }
}

/// The server calls the web reader makes, behind a protocol so tests use a fake.
/// Every call is authorized with the Mac's account session.
public protocol WebReaderAPI: Sendable {
    func devices() async throws -> [WebReaderDevice]
    func removeDevice(id: String) async throws
    /// `POST /v1/web-pairings/:id/approve {code}` (pre-v1.3 link pairing).
    func approvePairing(id: String, code: String) async throws
    /// `POST /v1/web-pairings/approve {code}`: v1.3, the code alone.
    func approvePairing(code: String) async throws
    /// `PUT /v1/snapshots/fasttab` then `PUT /v1/snapshots/fasttab/content`.
    func putSnapshot(version: Int, blob: WebSealedBlob) async throws
    /// Single JSON `PUT /v1/snapshots/fasttab/articles/:id {suite, wraps, ciphertext}`.
    func putArticle(id: String, blob: WebSealedBlob) async throws
    func deleteArticle(id: String) async throws
    /// `DELETE /v1/snapshots/fasttab`: snapshot, articles and pending highlights.
    func deleteSnapshot() async throws
    func pendingInbox(after cursor: String?) async throws -> WebInboxPage
    func ackInbox(ids: [String]) async throws
}

public struct WebReaderAPIError: Error, Equatable, CustomStringConvertible {
    public var status: Int
    public var code: String
    public var message: String
    public var description: String { "\(status) \(code): \(message)" }
}

/// URLSession implementation against theindie-api. `token` reads the session token on each
/// call (the account session owns it).
public struct LiveWebReaderAPI: WebReaderAPI {
    public let baseURL: URL
    public let token: @Sendable () -> String?
    public let urlSession: URLSession
    static let app = "fasttab"

    public init(baseURL: URL, urlSession: URLSession = .shared, token: @escaping @Sendable () -> String?) {
        self.baseURL = baseURL
        self.urlSession = urlSession
        self.token = token
    }

    private struct DeviceDTO: Decodable {
        /// Server spells it `deviceID` (shared with every app's /v1/me/devices client).
        let deviceID: String
        let publicKey: String
        let app: String
        let platform: String
        let name: String?
        let createdAt: Double?
        let lastSeenAt: Double?
    }

    private struct DevicesDTO: Decodable { let devices: [DeviceDTO] }

    public func devices() async throws -> [WebReaderDevice] {
        try Self.decodeDevices(try await send("GET", "/v1/me/devices"))
    }

    static func decodeDevices(_ data: Data) throws -> [WebReaderDevice] {
        try JSONDecoder().decode(DevicesDTO.self, from: data).devices.map {
            WebReaderDevice(
                id: $0.deviceID, platform: $0.platform, app: $0.app, name: $0.name, publicKey: $0.publicKey,
                createdAt: $0.createdAt.map { Date(timeIntervalSince1970: $0 / 1000) },
                lastSeenAt: $0.lastSeenAt.map { Date(timeIntervalSince1970: $0 / 1000) })
        }
    }

    public func removeDevice(id: String) async throws {
        _ = try await send("DELETE", "/v1/devices/\(id)")
    }

    public func approvePairing(id: String, code: String) async throws {
        _ = try await send("POST", "/v1/web-pairings/\(escape(id))/approve", json: ["code": code])
    }

    public func approvePairing(code: String) async throws {
        _ = try await send("POST", "/v1/web-pairings/approve", json: ["code": code])
    }

    private struct EnvelopeDTO: Encodable {
        let version: Int
        let suite: String
        let wraps: [WebKeyWrap]
        let contentSize: Int
    }

    public func putSnapshot(version: Int, blob: WebSealedBlob) async throws {
        let path = "/v1/snapshots/\(Self.app)"
        _ = try await send("PUT", path, body: try JSONEncoder().encode(EnvelopeDTO(
            version: version, suite: blob.suite, wraps: blob.wraps, contentSize: blob.ciphertext.count)))
        _ = try await send("PUT", path + "/content", body: blob.ciphertext, contentType: "application/octet-stream")
    }

    private struct ArticleDTO: Encodable {
        let suite: String
        let wraps: [WebKeyWrap]
        let ciphertext: String
    }

    public func putArticle(id: String, blob: WebSealedBlob) async throws {
        _ = try await send("PUT", "/v1/snapshots/\(Self.app)/articles/\(escape(id))", body: try JSONEncoder().encode(
            ArticleDTO(suite: blob.suite, wraps: blob.wraps, ciphertext: Base64URL.encode(blob.ciphertext))))
    }

    public func deleteArticle(id: String) async throws {
        _ = try await send("DELETE", "/v1/snapshots/\(Self.app)/articles/\(escape(id))")
    }

    public func deleteSnapshot() async throws {
        _ = try await send("DELETE", "/v1/snapshots/\(Self.app)")
    }

    public func pendingInbox(after cursor: String?) async throws -> WebInboxPage {
        var path = "/v1/snapshots/\(Self.app)/highlights"
        if let cursor { path += "?after=" + escape(cursor) }
        // Server shape: {items:[{id, articleId, createdAt, suite, wrap, ciphertext}], nextCursor, hasMore}.
        struct ItemDTO: Decodable {
            let id: String, articleId: String, suite: String, wrap: WebKeyWrap?, ciphertext: String
        }
        struct PageDTO: Decodable { let items: [ItemDTO]; let nextCursor: String?; let hasMore: Bool? }
        let page = try JSONDecoder().decode(PageDTO.self, from: try await send("GET", path))
        return WebInboxPage(
            items: page.items.map {
                WebInboxItem(id: $0.id, articleId: $0.articleId, suite: $0.suite,
                             wraps: $0.wrap.map { [$0] } ?? [], ciphertext: $0.ciphertext)
            },
            cursor: page.hasMore == true ? page.nextCursor : nil)
    }

    public func ackInbox(ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        _ = try await send("POST", "/v1/snapshots/\(Self.app)/highlights/ack", json: ["ids": ids])
    }

    // MARK: - Plumbing

    private func escape(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?&=")))
            ?? text
    }

    private func send(_ method: String, _ path: String, json: some Encodable) async throws -> Data {
        try await send(method, path, body: try JSONEncoder().encode(json))
    }

    private func send(_ method: String, _ path: String, body: Data? = nil,
                      contentType: String = "application/json") async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        guard let token = token() else {
            throw WebReaderAPIError(status: 401, code: "unauthorized", message: "Not signed in")
        }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await urlSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            struct ErrorBody: Decodable { struct Inner: Decodable { let code: String; let message: String? }; let error: Inner }
            let parsed = try? JSONDecoder().decode(ErrorBody.self, from: data)
            throw WebReaderAPIError(status: status, code: parsed?.error.code ?? "http_\(status)",
                                    message: parsed?.error.message ?? "")
        }
        return data
    }
}
