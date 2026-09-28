import Foundation
import IndieAccount
import IndiePowerUps
import IndieTranscripts

/// Loads a YouTube video's transcript from theindie-api and builds the reader article.
/// Closures are the seams tests stub; `live` talks to the real server.
struct YouTubeTranscriptLoader: Sendable {
    var fetchTranscript: @Sendable (_ videoID: String, _ lang: String?) async throws -> Transcript
    /// Best effort: the channel name for the byline, nil when unknown.
    var fetchChannel: @Sendable (_ videoURL: URL) async -> String?

    // TODO(aiReformat): when theindie-api gains a reformat endpoint, add a `reformat` seam here,
    // gated by `PowerUpGate.isEnabled(.aiReformat)` and a server capability check. No UI until then.
    static let supportsAIReformat = false

    func article(url: URL, videoID: String, title: String) async throws -> ReaderArticle {
        async let channel = fetchChannel(url)
        let transcript = try await fetchTranscript(videoID, Self.preferredLang())
        return TranscriptArticleBuilder.article(
            from: transcript, url: url, videoID: videoID, title: title, channel: await channel)
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
                return tokens.token().map { ["Authorization": "Bearer \($0)"] } ?? [:]
            }
        )
        return YouTubeTranscriptLoader(
            fetchTranscript: { try await client.transcript(videoId: $0, lang: $1) },
            fetchChannel: { await Self.oEmbedChannel(for: $0) }
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
