import Foundation
import IndieAccount
import IndiePowerUps
import IndieTranscripts
import os

/// Loads a YouTube video's transcript from theindie-api and builds the reader article.
/// Closures are the seams tests stub; `live` talks to the real server.
struct YouTubeTranscriptLoader: Sendable {
    var fetchTranscript: @Sendable (_ videoID: String, _ lang: String?) async throws -> Transcript
    /// Best effort: the channel name for the byline, nil when unknown.
    var fetchChannel: @Sendable (_ videoURL: URL) async -> String?
    /// On-device YouTube fetch, used when YouTube refuses the server (LOGIN_REQUIRED bot check)
    /// or the server's upstream call failed. nil: no fallback.
    var fetchOnDevice: (@Sendable (_ videoID: String, _ lang: String) async throws -> Transcript)?
    /// Fire-and-forget: offers an on-device transcript to the server cache.
    var uploadTranscript: (@Sendable (_ transcript: Transcript, _ requestedLang: String) async throws -> Void)?

    /// The server's default when no lang is sent (theindie-api routes/youtube.ts).
    static let serverDefaultLang = "en"
    private static let log = Logger(subsystem: "app.theindie.FastTabMobile", category: "transcript")

    init(fetchTranscript: @escaping @Sendable (_ videoID: String, _ lang: String?) async throws -> Transcript,
         fetchChannel: @escaping @Sendable (_ videoURL: URL) async -> String?,
         fetchOnDevice: (@Sendable (_ videoID: String, _ lang: String) async throws -> Transcript)? = nil,
         uploadTranscript: (@Sendable (_ transcript: Transcript, _ requestedLang: String) async throws -> Void)? = nil) {
        self.fetchTranscript = fetchTranscript
        self.fetchChannel = fetchChannel
        self.fetchOnDevice = fetchOnDevice
        self.uploadTranscript = uploadTranscript
    }

    // TODO(aiReformat): when theindie-api gains a reformat endpoint, add a `reformat` seam here,
    // gated by `PowerUpGate.isEnabled(.aiReformat)` and a server capability check. No UI until then.
    static let supportsAIReformat = false

    func article(url: URL, videoID: String, title: String) async throws -> ReaderArticle {
        async let channel = fetchChannel(url)
        let transcript = try await transcript(videoID: videoID, lang: Self.preferredLang())
        return TranscriptArticleBuilder.article(
            from: transcript, url: url, videoID: videoID, title: title, channel: await channel)
    }

    /// Server first; on `loginRequired` or 502, the phone fetches from YouTube itself and
    /// shares the result with the server cache in the background.
    func transcript(videoID: String, lang: String?) async throws -> Transcript {
        do {
            return try await fetchTranscript(videoID, lang)
        } catch let serverError as TranscriptError where Self.shouldFetchOnDevice(after: serverError) {
            guard let fetchOnDevice else { throw serverError }
            let requestedLang = lang ?? Self.serverDefaultLang
            let transcript: Transcript
            do {
                transcript = try await fetchOnDevice(videoID, requestedLang)
            } catch YouTubeCaptionError.loginRequired {
                throw TranscriptError.loginRequired
            } catch YouTubeCaptionError.noCaptions {
                throw TranscriptError.noCaptions
            } catch {
                Self.log.error("on-device transcript failed: \(String(describing: error), privacy: .public)")
                throw serverError
            }
            if let uploadTranscript {
                Task.detached(priority: .utility) {
                    do { try await uploadTranscript(transcript, requestedLang) } catch {
                        Self.log.error("transcript upload failed: \(String(describing: error), privacy: .public)")
                    }
                }
            }
            return transcript
        }
    }

    static func shouldFetchOnDevice(after error: TranscriptError) -> Bool {
        error == .loginRequired || error == .server(status: 502)
    }

    /// The device's first preferred language as a bare code ("en-US" → "en"); the server
    /// falls back to what the video has.
    static func preferredLang(_ preferred: [String] = Locale.preferredLanguages) -> String? {
        guard let first = preferred.first, !first.isEmpty else { return nil }
        return Locale(identifier: first).language.languageCode?.identifier ?? first
    }

    static var live: YouTubeTranscriptLoader {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(YouTubeTranscriptFixture.launchArgument) {
            return YouTubeTranscriptLoader(fetchTranscript: { id, _ in YouTubeTranscriptFixture.transcript(videoID: id) },
                                           fetchChannel: { _ in "Fixture Channel" })
        }
        #endif
        let client = TranscriptClient(
            baseURL: TheIndieServerConfiguration.baseURL(configuration: .fastTab),
            gate: .allEnabled,
            authHeaders: {
                let tokens = SessionTokenStore(keychain: KeychainStore(service: IndieAccountConfiguration.fastTab.keychainService))
                // No token: the server would answer 401, so don't make the call.
                guard let token = tokens.token() else { throw TranscriptError.notSignedIn }
                return ["Authorization": "Bearer \(token)"]
            }
        )
        let onDevice = YouTubeCaptionFetcher()
        return YouTubeTranscriptLoader(
            fetchTranscript: { try await client.transcript(videoId: $0, lang: $1) },
            fetchChannel: { await Self.oEmbedChannel(for: $0) },
            fetchOnDevice: { try await onDevice.transcript(videoId: $0, lang: $1) },
            uploadTranscript: { try await client.upload($0, requestedLang: $1) }
        )
    }

    /// YouTube's public oEmbed gives the channel name without an API key.
    private static func oEmbedChannel(for videoURL: URL) async -> String? {
        var components = URLComponents(string: "https://www.youtube.com/oembed")
        components?.queryItems = [URLQueryItem(name: "url", value: videoURL.absoluteString),
                                  URLQueryItem(name: "format", value: "json")]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        struct OEmbed: Decodable { let author_name: String? }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (try? JSONDecoder().decode(OEmbed.self, from: data))?.author_name
    }
}
