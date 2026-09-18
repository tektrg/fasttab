import Foundation

/// Extracted article content returned by `ReaderExtractor`.
public struct ReaderArticle: Codable, Equatable, Sendable {
    public let title: String
    public let byline: String       // author / publication
    public let siteName: String
    public let content: String      // sanitised inner HTML from Readability
    public let excerpt: String      // short plain-text summary
    public let url: URL
    public let extractedAt: Date

    public init(
        title: String,
        byline: String = "",
        siteName: String = "",
        content: String,
        excerpt: String = "",
        url: URL,
        extractedAt: Date = Date()
    ) {
        self.title = title
        self.byline = byline
        self.siteName = siteName
        self.content = content
        self.excerpt = excerpt
        self.url = url
        self.extractedAt = extractedAt
    }

    public var isEmpty: Bool {
        content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - URL Canonicalization

public extension URL {
    /// Canonical key for reader article cache, reading progress, and highlights.
    /// Normalizes URL by:
    /// 1. Stripping fragment anchors (`#...`)
    /// 2. Stripping tracking/analytics query parameters (`utm_*`, `ref`, `fbclid`, etc.)
    /// 3. Sorting remaining query parameters deterministically
    /// 4. Lowercasing scheme and host
    var readerCanonicalKey: String {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: true) else {
            return absoluteString.lowercased()
        }
        components.fragment = nil

        let trackingParams: Set<String> = [
            "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content",
            "ref", "fbclid", "gclid", "twclid", "igshid", "mc_cid", "mc_eid"
        ]

        if let queryItems = components.queryItems, !queryItems.isEmpty {
            let filtered = queryItems.filter { !trackingParams.contains($0.name.lowercased()) }
            if filtered.isEmpty {
                components.queryItems = nil
            } else {
                components.queryItems = filtered.sorted { $0.name < $1.name }
            }
        } else {
            components.queryItems = nil
        }

        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()

        return components.url?.absoluteString ?? absoluteString.lowercased()
    }
}
