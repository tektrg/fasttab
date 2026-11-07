import CryptoKit
import Foundation

// The decrypted payloads of the Fast Tab web reader, as fixed by the sync contract
// (`memory/Projects/fasttab-web-reader/contract.md`). The Mac writes `WebSnapshot` and
// `WebArticleBody`; the browser writes `WebHighlight` and `WebProgress`.

/// `fasttab.web.snapshot/1`: what the browser shows (tabs, bookmarks, lists, article index).
public struct WebSnapshot: Codable, Equatable, Sendable {
    public static let schemaID = "fasttab.web.snapshot/1"

    public var schema: String = WebSnapshot.schemaID
    public var generatedAt: String
    public var macName: String
    public var windows: [Window]
    public var bookmarks: BookmarkNode
    public var lists: [List]
    public var articles: [Article]

    public struct Window: Codable, Equatable, Sendable {
        public var id: String
        public var tabs: [Tab]
    }

    public struct Tab: Codable, Equatable, Sendable {
        public var id: String
        public var url: String
        public var title: String
        public var favIconUrl: String?
        public var lastActiveAt: String?
    }

    /// A folder (`children` set) or a bookmark (`url` set).
    public struct BookmarkNode: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var url: String?
        public var children: [BookmarkNode]?
    }

    public struct List: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        /// `upNext` or `list`.
        public var kind: String
        public var items: [ListItem]
    }

    public struct ListItem: Codable, Equatable, Sendable {
        public var id: String
        public var url: String
        public var title: String
        public var addedAt: String
        public var articleId: String?
    }

    public struct Article: Codable, Equatable, Sendable {
        public var id: String
        public var url: String
        public var title: String
        public var byline: String?
        public var contentHash: String
        public var size: Int
    }
}

/// `fasttab.web.article/1`: one article body, uploaded as its own encrypted blob.
public struct WebArticleBody: Codable, Equatable, Sendable {
    public static let schemaID = "fasttab.web.article/1"

    public var schema: String = WebArticleBody.schemaID
    public var url: String
    public var title: String
    public var byline: String?
    public var html: String
    public var textLength: Int

    public init(url: String, title: String, byline: String?, html: String, textLength: Int) {
        self.url = url
        self.title = title
        self.byline = byline
        self.html = html
        self.textLength = textLength
    }

    /// Sorted-key JSON: the same body always gives the same bytes, so the same `contentHash`.
    public func encoded() throws -> Data { try WebReaderJSON.encoder.encode(self) }
}

/// `fasttab.web.highlight/1`, from the browser.
public struct WebHighlight: Codable, Equatable, Sendable {
    public static let schemaID = "fasttab.web.highlight/1"
    public var schema: String
    public var url: String
    public var quote: String
    public var prefix: String
    public var suffix: String
    public var color: String
    public var note: String?
    public var createdAt: String
}

/// `fasttab.web.progress/1`, from the browser.
public struct WebProgress: Codable, Equatable, Sendable {
    public static let schemaID = "fasttab.web.progress/1"
    public var schema: String
    public var url: String
    public var fraction: Double
    public var updatedAt: String
}

public enum WebReaderJSON {
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    nonisolated(unsafe) static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) static let isoFormatterNoFraction = ISO8601DateFormatter()

    public static func iso(_ date: Date) -> String { isoFormatter.string(from: date) }

    public static func date(_ text: String) -> Date? {
        isoFormatter.date(from: text) ?? isoFormatterNoFraction.date(from: text)
    }

    /// Lowercase hex SHA-256.
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The contract's `articleId` (v1.1): hex SHA-256 of the URL with its `#fragment` cut,
    /// no other normalization, first 32 chars. The browser computes the same for any link.
    public static func articleID(for url: String) -> String {
        let bare = url.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? url
        return String(sha256Hex(Data(bare.utf8)).prefix(32))
    }
}
