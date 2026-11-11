import Foundation
import IndieAccount
import UIKit

/// Body of theindie-api `POST /v1/ai/reader-summary`. `instruction` stays nil until the person
/// edits the prompt (the server then uses its versioned default).
struct ReaderSummaryRequest: Encodable, Equatable, Sendable {
    let text: String
    let languageCode: String?
    let instruction: String?
    let promptVersion: Int?

    init(text: String, languageCode: String?, instruction: String? = nil, promptVersion: Int? = nil) {
        self.text = text
        self.languageCode = languageCode
        self.instruction = instruction
        self.promptVersion = promptVersion
    }
}

struct ReaderSummaryResponse: Decodable, Equatable, Sendable {
    struct Usage: Decodable, Equatable, Sendable { let remaining: Int? }
    let summary: String
    let model: String
    let promptVersion: Int?
    let defaultInstructionVersion: Int?
    /// The answer hit the server's length limit and may end early (absent on older servers).
    let truncated: Bool?
    let usage: Usage?
}

/// Why a summary couldn't be made; each case has its own wording in the sheet.
enum ReaderSummaryError: Error, Equatable {
    /// 402 `reader_ai_subscription_required`.
    case subscriptionRequired
    /// 402 `reader_ai_user_quota`: this month's allowance is used up.
    case quotaExhausted(resetsAt: Date?)
    /// 400 `reader_ai_text_too_short` (never charged).
    case tooShort
    /// 401: no session.
    case notSignedIn
    /// 429: more than the per-minute limit.
    case rateLimited
    /// No network.
    case offline
    /// 5xx (disabled, ceiling, provider failure), bad answer, anything else.
    case unavailable
}

/// Asks theindie-api for a summary. `send` is the seam tests replace.
struct ReaderSummaryClient: Sendable {
    typealias Send = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// A summary call waits on a language model; the server allows ~60 s upstream.
    static let timeout: TimeInterval = 90

    let endpoint: URL
    let headers: @Sendable () -> [String: String]
    let send: Send

    func summarize(_ request: ReaderSummaryRequest) async throws -> ReaderSummaryResponse {
        var urlRequest = URLRequest(url: endpoint, timeoutInterval: Self.timeout)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = try JSONEncoder().encode(request)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers() { urlRequest.setValue(value, forHTTPHeaderField: name) }
        let body: Data
        let status: Int
        do {
            let (data, response) = try await send(urlRequest)
            body = data
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError where Self.offlineCodes.contains(error.code) {
            throw ReaderSummaryError.offline
        } catch {
            throw ReaderSummaryError.unavailable
        }
        guard status == 200 else {
            let code = NaturalVoiceClient.errorCode(in: body) ?? "-"
            readerSummaryLog.error("reader summary HTTP \(status) code \(code, privacy: .public)")
            throw Self.error(status: status, body: body)
        }
        guard let decoded = try? JSONDecoder().decode(ReaderSummaryResponse.self, from: body),
              !decoded.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ReaderSummaryError.unavailable
        }
        return decoded
    }

    private static let offlineCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff,
    ]

    /// Maps a non-200 answer onto what the sheet should say.
    static func error(status: Int, body: Data) -> ReaderSummaryError {
        struct ErrorBody: Decodable { let code: String?; let resetsAt: String? }
        let decoded = try? JSONDecoder().decode(ErrorBody.self, from: body)
        let code = decoded?.code ?? NaturalVoiceClient.errorCode(in: body)
        switch (status, code) {
        case (402, "reader_ai_subscription_required"): return .subscriptionRequired
        case (402, _): return .quotaExhausted(resetsAt: decoded?.resetsAt.flatMap(parseDate))
        case (400, "reader_ai_text_too_short"): return .tooShort
        case (401, _): return .notSignedIn
        case (429, _): return .rateLimited
        default: return .unavailable
        }
    }

    private static func parseDate(_ raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }

    static var live: ReaderSummaryClient {
        ReaderSummaryClient(
            endpoint: TheIndieServerConfiguration.baseURL(configuration: .fastTab).appending(path: "v1/ai/reader-summary"),
            headers: { NaturalVoiceClient.identityHeaders() },
            send: { request in
                // The answer takes 10-20 s; keep the request alive if the phone locks meanwhile
                // (a dropped request would have been charged but never delivered).
                let grant = await BackgroundGrant.begin()
                do {
                    let result = try await URLSession.shared.data(for: request)
                    await grant.end()
                    return result
                } catch {
                    await grant.end()
                    throw error
                }
            })
    }
}

/// A UIKit background-time grant around one request. If iOS runs out of grace time first, the
/// expiration handler ends it (iOS kills an app that doesn't); `end()` is safe to call twice.
final class BackgroundGrant: @unchecked Sendable {
    @MainActor private var identifier: UIBackgroundTaskIdentifier = .invalid

    @MainActor static func begin(name: String = "reader-summary") -> BackgroundGrant {
        let grant = BackgroundGrant()
        grant.identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak grant] in
            MainActor.assumeIsolated { grant?.end() }
        }
        return grant
    }

    @MainActor func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
