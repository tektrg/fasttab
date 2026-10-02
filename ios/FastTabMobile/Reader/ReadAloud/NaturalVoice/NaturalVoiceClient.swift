import Foundation
import IndieAccount

/// One sentence to synthesise (body of theindie-api `POST /v1/tts`).
struct NaturalVoiceRequest: Codable, Equatable, Sendable {
    let text: String
    let languageCode: String
    let voice: String?
    let speakingRate: Double
}

/// Why the natural voice can't speak; each case maps to a fallback notice.
enum NaturalVoiceError: Error, Equatable {
    /// 402 `tts_user_quota`: this user's monthly characters are used up.
    case quotaExhausted(resetsAt: Date?)
    /// 503 `tts_ceiling` / `tts_disabled`, 502 (Google failed), repeated 429, other errors,
    /// or no network: the rest of the article goes to the device voice.
    case unavailable
    /// 400 `tts_rejected`: Google refused this one sentence; only it uses the device voice.
    case sentenceRejected
}

/// Fetches MP3 audio for a sentence: on-device cache first, then the server.
/// `send` (HTTP) and `sleep` (429 backoff) are the seams tests replace.
struct NaturalVoiceClient: Sendable {
    typealias Send = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let rateLimitBackoff: Duration = .milliseconds(800)

    let endpoint: URL
    let cache: NaturalVoiceAudioCache
    let headers: @Sendable () -> [String: String]
    let send: Send
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    func audio(for request: NaturalVoiceRequest) async throws -> Data {
        let key = NaturalVoiceAudioCache.key(for: request)
        if let cached = cache.audio(forKey: key) { return cached }
        var (status, body) = try await fetch(request)
        if status == 429 { // rate-limited: one retry after a short pause, then give up
            try await sleep(Self.rateLimitBackoff)
            (status, body) = try await fetch(request)
        }
        if status == 200 {
            cache.store(body, forKey: key)
            return body
        }
        readAloudLog.error("natural voice HTTP \(status)")
        throw Self.error(status: status, body: body)
    }

    /// Maps a non-200 answer onto what Read Aloud should do about it.
    static func error(status: Int, body: Data) -> NaturalVoiceError {
        struct ErrorBody: Decodable { let code: String?; let resetsAt: String? }
        let decoded = try? JSONDecoder().decode(ErrorBody.self, from: body)
        switch (status, decoded?.code) {
        case (402, _): return .quotaExhausted(resetsAt: decoded?.resetsAt.flatMap(parseDate))
        case (400, "tts_rejected"): return .sentenceRejected
        default: return .unavailable
        }
    }

    private func fetch(_ request: NaturalVoiceRequest) async throws -> (status: Int, body: Data) {
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = try JSONEncoder().encode(request)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        for (name, value) in headers() { urlRequest.setValue(value, forHTTPHeaderField: name) }
        do {
            let (body, response) = try await send(urlRequest)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, body)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            readAloudLog.error("natural voice network error: \(error.localizedDescription)")
            throw NaturalVoiceError.unavailable
        }
    }

    private static func parseDate(_ raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }

    static var live: NaturalVoiceClient {
        let keychain = KeychainStore(service: IndieAccountConfiguration.fastTab.keychainService)
        return NaturalVoiceClient(
            endpoint: TheIndieServerConfiguration.baseURL(configuration: .fastTab).appending(path: "v1/tts"),
            cache: NaturalVoiceAudioCache(),
            headers: {
                // Same identification as the transcript calls (bearer when signed in) + this install.
                var headers = ["X-Install-Id": NaturalVoiceInstallID.value(in: keychain)]
                if let token = SessionTokenStore(keychain: keychain).token() {
                    headers["Authorization"] = "Bearer \(token)"
                }
                return headers
            },
            send: { try await URLSession.shared.data(for: $0) }
        )
    }
}

/// Random id made once per install and kept in the Keychain (survives reinstall-free
/// updates, not synced), so the server can meter anonymous use per device.
enum NaturalVoiceInstallID {
    static func value(in keychain: KeychainStoring) -> String {
        if let data = try? keychain.readData(account: KeychainAccount.installID),
           let existing = String(data: data, encoding: .utf8), !existing.isEmpty {
            return existing
        }
        let created = UUID().uuidString.lowercased()
        try? keychain.writeData(Data(created.utf8), account: KeychainAccount.installID)
        return created
    }
}
