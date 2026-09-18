import Foundation
import LinkPresentation
import UIKit

public struct LinkPreview: Sendable {
    public let title: String?
    public let image: UIImage?
    public let authorName: String?
    public let authorHandle: String?
    public let snippetText: String?
    public let isTweet: Bool

    public init(
        title: String? = nil,
        image: UIImage? = nil,
        authorName: String? = nil,
        authorHandle: String? = nil,
        snippetText: String? = nil,
        isTweet: Bool = false
    ) {
        self.title = title
        self.image = image
        self.authorName = authorName
        self.authorHandle = authorHandle
        self.snippetText = snippetText
        self.isTweet = isTweet
    }
}

/// Fetches an Open Graph-style preview (title + image) for a URL via the
/// system `LinkPresentation` framework — the same mechanism Messages/Safari
/// use for rich link previews, with an oEmbed fast-path for Twitter/X status URLs.
///
/// `LPMetadataProvider` instances are single-use, so a fresh one is created
/// per fetch. Results are cached in memory, and concurrent requests for the
/// same URL (e.g. the top few cards of the deck loading at once) share one
/// in-flight fetch instead of hitting the network twice.
@MainActor
public final class LinkPreviewLoader {
    public static let shared = LinkPreviewLoader()

    /// Maximum cached previews before the oldest entry is evicted.
    /// Each preview can hold a UIImage of several MB, so this bounds
    /// total memory to a reasonable ceiling (~50 images).
    private static let maxCacheEntries = 50

    private var cache: [String: LinkPreview] = [:]
    /// Insertion-order keys for LRU eviction. Newest entries are appended;
    /// oldest entries are removed from the front when the cap is exceeded.
    private var cacheOrder: [String] = []
    private var inFlight: [String: Task<LinkPreview, Never>] = [:]

    public init() {}

    public func preview(for url: URL) async -> LinkPreview {
        let key = url.absoluteString
        if let cached = cache[key] {
            // Promote to most-recently-used
            if let idx = cacheOrder.firstIndex(of: key) {
                cacheOrder.remove(at: idx)
                cacheOrder.append(key)
            }
            return cached
        }
        if let existing = inFlight[key] {
            return await existing.value
        }

        let task = Task<LinkPreview, Never> {
            if Self.isTwitterStatusURL(url) {
                if let tweetPreview = await Self.fetchTwitterEmbed(for: url) {
                    return tweetPreview
                }
            }
            return await Self.fetchStandardPreview(for: url)
        }
        inFlight[key] = task

        let result = await task.value
        insertIntoCache(key: key, preview: result)
        inFlight[key] = nil
        return result
    }

    private static func fetchStandardPreview(for url: URL) async -> LinkPreview {
        let provider = LPMetadataProvider()
        let metadata = try? await provider.startFetchingMetadata(for: url)
        let image = await Self.loadImage(from: metadata?.imageProvider)
        return LinkPreview(title: metadata?.title, image: image)
    }

    private func insertIntoCache(key: String, preview: LinkPreview) {
        cache[key] = preview
        // Remove any existing entry to prevent duplicate keys in the order
        // array, which would desynchronize eviction from the dictionary.
        if let idx = cacheOrder.firstIndex(of: key) {
            cacheOrder.remove(at: idx)
        }
        cacheOrder.append(key)
        while cacheOrder.count > Self.maxCacheEntries {
            let evicted = cacheOrder.removeFirst()
            cache.removeValue(forKey: evicted)
        }
    }

    private static func loadImage(from itemProvider: NSItemProvider?) async -> UIImage? {
        guard let itemProvider, itemProvider.canLoadObject(ofClass: UIImage.self) else { return nil }
        return await withCheckedContinuation { continuation in
            itemProvider.loadObject(ofClass: UIImage.self) { object, _ in
                continuation.resume(returning: object as? UIImage)
            }
        }
    }

    // MARK: - Twitter / X oEmbed

    public static func isTwitterURL(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        return host == "x.com" || host == "www.x.com" || host.hasSuffix(".x.com") ||
               host == "twitter.com" || host == "www.twitter.com" || host.hasSuffix(".twitter.com")
    }

    public static func isTwitterStatusURL(_ url: URL) -> Bool {
        guard isTwitterURL(url) else { return false }
        return url.path.contains("/status/")
    }

    private static func fetchTwitterEmbed(for url: URL) async -> LinkPreview? {
        guard isTwitterStatusURL(url) else { return nil }
        var components = URLComponents(string: "https://publish.twitter.com/oembed")
        components?.queryItems = [
            URLQueryItem(name: "url", value: url.absoluteString),
            URLQueryItem(name: "omit_script", value: "true")
        ]
        guard let oembedURL = components?.url else { return nil }

        do {
            var request = URLRequest(url: oembedURL)
            request.timeoutInterval = 4.0
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return nil
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            let authorName = json["author_name"] as? String
            let authorURL = json["author_url"] as? String
            let handle: String? = {
                if let authorURL, let parsed = URL(string: authorURL) {
                    let last = parsed.lastPathComponent
                    if !last.isEmpty && last != "/" {
                        return "@" + last
                    }
                }
                return nil
            }()
            let html = json["html"] as? String ?? ""
            let snippet = extractTweetSnippet(from: html)
            let title = !snippet.isEmpty ? snippet : (authorName ?? "X Post")

            return LinkPreview(
                title: title,
                image: nil,
                authorName: authorName,
                authorHandle: handle,
                snippetText: snippet,
                isTweet: true
            )
        } catch {
            return nil
        }
    }

    public static func extractTweetSnippet(from html: String) -> String {
        guard let pStart = html.range(of: "<p")?.lowerBound,
              let pContentStart = html[pStart...].range(of: ">")?.upperBound,
              let pEnd = html[pContentStart...].range(of: "</p>")?.lowerBound else {
            return ""
        }
        let rawParagraph = String(html[pContentStart..<pEnd])

        // Pre-replace break tags with newlines before stripping remaining HTML tags
        var text = rawParagraph.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)

        // Decode common HTML entities (decode &amp; last to avoid double decoding like &amp;lt;)
        text = text
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&#8217;", with: "’")
            .replacingOccurrences(of: "&rsquo;", with: "’")
            .replacingOccurrences(of: "&#8216;", with: "‘")
            .replacingOccurrences(of: "&lsquo;", with: "‘")
            .replacingOccurrences(of: "&#8220;", with: "“")
            .replacingOccurrences(of: "&ldquo;", with: "“")
            .replacingOccurrences(of: "&#8221;", with: "”")
            .replacingOccurrences(of: "&rdquo;", with: "”")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&mdash;", with: "—")
            .replacingOccurrences(of: "&ndash;", with: "–")
            .replacingOccurrences(of: "&hellip;", with: "…")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&#10;", with: "\n")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "\n\n+", with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return text
    }
}
