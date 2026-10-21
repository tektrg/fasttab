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
    /// Set when `content` is a YouTube transcript (`TranscriptArticleBuilder`); the reader
    /// then offers the corner player. Nil for Readability articles and older cache entries.
    public let youtubeVideoID: String?

    public init(
        title: String,
        byline: String = "",
        siteName: String = "",
        content: String,
        excerpt: String = "",
        url: URL,
        extractedAt: Date = Date(),
        youtubeVideoID: String? = nil
    ) {
        self.title = title
        self.byline = byline
        self.siteName = siteName
        self.content = content
        self.excerpt = excerpt
        self.url = url
        self.extractedAt = extractedAt
        self.youtubeVideoID = youtubeVideoID
    }

    public var isEmpty: Bool {
        content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// URL canonicalization (`readerCanonicalKey`) lives in FastTabSync: the FastTab List's
// item id derives from it, and the Mac must compute the same ids.
