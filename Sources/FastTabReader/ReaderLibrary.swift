import FastTabSync
import Foundation
import IndieComments

/// A reader highlight as synced from the phone (the fields of its `ReaderHighlight` JSON the
/// Mac uses). Unknown fields are ignored, missing optional ones stay nil.
public struct ReaderHighlightInfo: Decodable, Hashable, Sendable {
    public let id: String
    public let urlKey: String
    public let selectedText: String
    /// `yellow`, `green`, `blue` or `pink`.
    public let color: String
    public let serializedRange: String
    public let createdAt: Date
    public let title: String?
    public let urlString: String?
    public let tags: [String]?
    public let commentThreadId: String?

    public var articleURL: URL? { urlString.flatMap(URL.init(string:)) ?? URL(string: urlKey) }

    /// The article scrolled to the passage: a text fragment (`#:~:text=start,end`) that
    /// Safari and Chromium browsers highlight. Long quotes use their first and last words.
    public var urlAtHighlight: URL? {
        guard let url = articleURL, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return articleURL
        }
        let words = selectedText.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return url }
        func encode(_ text: String) -> String {
            var allowed = CharacterSet.urlFragmentAllowed
            allowed.remove(charactersIn: "&,-#")
            return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
        }
        let fragment = words.count <= 8
            ? encode(words.joined(separator: " "))
            : encode(words.prefix(4).joined(separator: " ")) + "," + encode(words.suffix(4).joined(separator: " "))
        components.fragment = nil
        return URL(string: (components.string ?? url.absoluteString) + "#:~:text=" + fragment)
    }

    /// The page title, else the site.
    public var pageTitle: String {
        if let title, !title.trimmingCharacters(in: .whitespaces).isEmpty { return title }
        return site
    }

    /// The host without `www.`.
    public var site: String {
        let host = articleURL?.host() ?? urlKey
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    var anchor: TextAnchor {
        ReaderHighlightThreads.anchor(serializedRange: serializedRange, selectedText: selectedText)
    }
}

/// A highlight with its comment thread (nil until someone comments).
public struct HighlightEntry: Identifiable, Hashable, Sendable {
    public let highlight: ReaderHighlightInfo
    public let thread: CommentThread?
    public var id: String { highlight.id }

    /// `none`, `open` or `resolved`.
    public var status: String { thread.map { $0.state == .resolved ? "resolved" : "open" } ?? "none" }
    public var comments: [CommentEvent] { thread?.messages ?? [] }
}

/// The phone's highlights and their threads as the Mac mirror holds them, plus the comment
/// actions on them. Read fresh on every call, so the app and the MCP helper (another
/// process) always see each other's writes; only the app's sync writes highlights.
public struct ReaderLibrary: Sendable {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case highlightNotFound(String)
        case noThread(String)
        case emptyComment

        public var description: String {
            switch self {
            case .highlightNotFound(let id): "No highlight with id \(id)."
            case .noThread(let id): "Highlight \(id) has no comment thread yet; create one first."
            case .emptyComment: "The comment is empty."
            }
        }
    }

    public let directory: URL
    public let comments: CommentStore

    public init(directory: URL, comments: CommentStore? = nil) {
        self.directory = directory
        self.comments = comments ?? ReaderMirror.commentStore(in: directory)
    }

    /// Every highlight with its thread, newest first.
    public func entries() async -> [HighlightEntry] {
        let highlights = ReaderMirror.loadHighlights(in: directory).compactMap {
            try? JSONDecoder().decode(ReaderHighlightInfo.self, from: $0.payload)
        }
        var entries: [HighlightEntry] = []
        for (urlKey, group) in Dictionary(grouping: highlights, by: \.urlKey) {
            let docId = ReaderCommentDocID.forArticle(urlKey: urlKey)
            let threads = (try? await comments.threads(docId: docId, text: "")) ?? []
            let assigned = ReaderHighlightThreads.assign(
                group, threads: threads, id: \.id, linkedThreadId: \.commentThreadId,
                serializedRange: \.serializedRange, selectedText: \.selectedText)
            entries += group.map { HighlightEntry(highlight: $0, thread: assigned[$0.id]) }
        }
        return entries.sorted { $0.highlight.createdAt > $1.highlight.createdAt }
    }

    public func entry(id: String) async throws -> HighlightEntry {
        guard let entry = await entries().first(where: { $0.id == id }) else { throw Failure.highlightNotFound(id) }
        return entry
    }

    /// Adds a comment: opens the highlight's thread if it has none, replies otherwise (a reply
    /// on a resolved thread reopens it).
    @discardableResult
    public func comment(_ text: String, onHighlight id: String, by author: CommentAuthor) async throws -> HighlightEntry {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw Failure.emptyComment }
        let entry = try await entry(id: id)
        let docId = ReaderCommentDocID.forArticle(urlKey: entry.highlight.urlKey)
        if let thread = entry.thread {
            try await comments.reply(docId: docId, threadId: thread.id, author: author, text: body)
        } else {
            try await comments.openThread(docId: docId, author: author, anchor: entry.highlight.anchor, text: body)
        }
        return try await self.entry(id: id)
    }

    @discardableResult
    public func setResolved(_ resolved: Bool, onHighlight id: String, by author: CommentAuthor) async throws -> HighlightEntry {
        let entry = try await entry(id: id)
        guard let thread = entry.thread else { throw Failure.noThread(id) }
        let docId = ReaderCommentDocID.forArticle(urlKey: entry.highlight.urlKey)
        if resolved {
            try await comments.resolve(docId: docId, threadId: thread.id, author: author)
        } else {
            try await comments.reopen(docId: docId, threadId: thread.id, author: author)
        }
        return try await self.entry(id: id)
    }
}
