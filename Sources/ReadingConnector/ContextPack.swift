import FastTabReader
import Foundation

/// `context_pack`: the Ghostwriter brief. One markdown document for a period or a topic:
/// articles with the user's highlights and comments (commented ones first, then newest
/// activity), then "Read, no highlights", then "In progress". Fits `maxTokens` (~4 characters
/// a token): comments are never cut, quotes are trimmed to `quoteLimit`, and whatever does not
/// fit is counted ("+N more") with the URLs to ask `article(url)` about.
public struct ContextPack: Sendable {
    public static let defaultMaxTokens = 8_000
    public static let quoteLimit = 400
    static let charactersPerToken = 4

    public struct Request: Sendable {
        /// Start of the window; nil = all time (a topic pack with no period).
        public var since: Date?
        public var periodLabel: String?
        public var topic: String?
        public var maxTokens: Int

        public init(since: Date?, periodLabel: String?, topic: String?, maxTokens: Int = ContextPack.defaultMaxTokens) {
            self.since = since
            self.periodLabel = periodLabel
            self.topic = topic
            self.maxTokens = maxTokens
        }
    }

    /// One article in the brief.
    struct Article {
        let key: String
        let url: String
        let title: String
        let domain: String
        let item: ReadingItem?
        let highlights: [HighlightEntry]
        let lastActivity: Date
        var hasComments: Bool { highlights.contains { !$0.comments.isEmpty } }
    }

    public let connector: ReadingConnector
    public let format: ReadingFormat
    /// First sentences of fetched article text, when cached (slice 6); nil = none.
    public let summary: @Sendable (String) -> String?

    public init(connector: ReadingConnector, format: ReadingFormat, summary: @escaping @Sendable (String) -> String? = { _ in nil }) {
        self.connector = connector
        self.format = format
        self.summary = summary
    }

    public struct Result: Sendable {
        public let markdown: String
        public let articleCount: Int
        public let highlightCount: Int
        public let returnedIDs: [(id: String, title: String)]
    }

    public func build(_ request: Request) async -> Result {
        let words = ReadingConnector.words(request.topic)
        let allHighlights = await connector.highlights(limit: .max)
        let items = connector.items()
        let itemByKey = Dictionary(items.map { (Self.key($0.url), $0) }, uniquingKeysWith: { a, _ in a })

        // Highlights in the window (and on topic), grouped by page.
        let inWindow = allHighlights.filter { entry in
            request.since.map { entry.highlight.createdAt >= $0 } ?? true
        }
        var byPage: [String: [HighlightEntry]] = [:]
        for entry in inWindow { byPage[entry.highlight.urlKey, default: []].append(entry) }
        // A page read in the window keeps all its highlights, even ones made before the window
        // (a re-read): a writer wants those quotes, and "Read, no highlights" would be false.
        if let since = request.since {
            let activeKeys = Set(items.filter { $0.lastActivityAt >= since }.map { Self.key($0.url) })
            for entry in allHighlights where entry.highlight.createdAt < since && activeKeys.contains(entry.highlight.urlKey) {
                byPage[entry.highlight.urlKey, default: []].append(entry)
            }
        }

        func pageMatches(_ key: String, item: ReadingItem?, highlights: [HighlightEntry]) -> Bool {
            guard !words.isEmpty else { return true }
            let text = ([item?.displayTitle ?? "", item?.url ?? key]
                + highlights.map(ReadingConnector.searchableText)).joined(separator: "\n")
            return ReadingConnector.contains(words, in: text)
        }

        var articles: [Article] = byPage.compactMap { key, entries in
            let item = itemByKey[key]
            guard pageMatches(key, item: item, highlights: entries) else { return nil }
            let first = entries[0].highlight
            let sorted = entries.sorted { $0.highlight.createdAt < $1.highlight.createdAt }
            let last = max(entries.map(\.highlight.createdAt).max() ?? .distantPast, item?.lastActivityAt ?? .distantPast)
            return Article(key: key, url: item?.url ?? first.articleURL?.absoluteString ?? key,
                           title: item?.displayTitle ?? first.pageTitle, domain: item?.domain ?? first.site,
                           item: item, highlights: sorted, lastActivity: last)
        }
        articles.sort { a, b in
            if a.hasComments != b.hasComments { return a.hasComments }
            return (a.lastActivity, a.key) > (b.lastActivity, b.key)
        }

        let highlighted = Set(articles.map(\.key))
        let active = items.filter { item in
            (request.since.map { item.lastActivityAt >= $0 } ?? true)
                && !highlighted.contains(Self.key(item.url))
                && pageMatches(Self.key(item.url), item: item, highlights: [])
        }
        let readNoHighlights = active.filter { $0.matches(.read) }
        let inProgress = active.filter { $0.status == .reading }

        // Header.
        let highlightCount = articles.reduce(0) { $0 + $1.highlights.count }
        let commentCount = articles.reduce(0) { $0 + $1.highlights.reduce(0) { $0 + $1.comments.count } }
        var scope: [String] = []
        if let label = request.periodLabel, let since = request.since {
            scope.append("\(label) (\(format.day(since)) → \(format.day(connector.now())))")
        } else if request.since == nil {
            scope.append("all time")
        }
        if let topic = request.topic, !topic.isEmpty { scope.append("topic \"\(format.inline(topic))\"") }
        var out = [
            "# Reading brief — \(scope.joined(separator: ", "))",
            "",
            "\(format.count(articles.count, "article")) with highlights · \(format.count(highlightCount, "highlight")) · "
                + "\(format.count(commentCount, "comment")) · \(readNoHighlights.count) read without highlights · "
                + "\(inProgress.count) in progress",
            "",
            "_\(ReadingFormat.untrustedNotice)_",
        ]
        let budget = max(500, request.maxTokens) * Self.charactersPerToken
        var used = out.joined(separator: "\n").count
        var returned: [(id: String, title: String)] = []

        // Articles: whole blocks while they fit; the first always goes in.
        var skipped: [Article] = []
        for article in articles {
            let block = articleBlock(article)
            let size = block.joined(separator: "\n").count + 1
            if used + size > budget, !returned.isEmpty || !skipped.isEmpty {
                skipped.append(article)
                continue
            }
            out += block
            used += size
            returned += article.highlights.map { ($0.id, String($0.highlight.selectedText.prefix(80))) }
        }
        if !skipped.isEmpty {
            let urls = skipped.prefix(20).map { "\(format.link($0.url))" }.joined(separator: ", ")
            out += ["", "_+\(skipped.count) more \(skipped.count == 1 ? "article" : "articles") with highlights; "
                    + "call `article(url)` for: \(urls)\(skipped.count > 20 ? ", …" : "")_"]
        }

        // Two link lists, same budget.
        func list(_ title: String, _ items: [ReadingItem], line: (ReadingItem) -> String) {
            guard !items.isEmpty else { return }
            var lines = ["", "## \(title)"]
            var shown = 0
            for item in items {
                let text = "- " + line(item)
                guard used + text.count + 1 <= budget || shown == 0 else { break }
                lines.append(text)
                used += text.count + 1
                shown += 1
                returned.append((item.id, String(item.displayTitle.prefix(80))))
            }
            if shown < items.count { lines.append("- _+\(items.count - shown) more; call `reading_list` for all._") }
            out += lines
        }
        list("Read, no highlights", readNoHighlights) { item in
            "**\(format.inline(item.displayTitle))** — \(item.domain ?? "")"
                + (item.readCount > 1 ? " · read \(item.readCount)×" : "") + " · \(format.link(item.url))"
        }
        list("In progress", inProgress) { item in
            "**\(format.inline(item.displayTitle))** — \(item.domain ?? "") · \(format.percent(item.progress)) · \(format.link(item.url))"
        }
        if articles.isEmpty && readNoHighlights.isEmpty && inProgress.isEmpty {
            out += ["", "Nothing read or highlighted in this window."]
        }
        return Result(markdown: out.joined(separator: "\n") + "\n", articleCount: articles.count,
                      highlightCount: highlightCount, returnedIDs: returned)
    }

    func articleBlock(_ article: Article) -> [String] {
        var meta = [article.domain]
        if let item = article.item {
            if item.readCount > 0 { meta.append("read \(item.readCount)×") }
            meta.append(format.percent(item.progress))
        }
        meta.append("\(format.link(article.url))")
        var lines = ["", "## \(format.inline(article.title)) — " + meta.joined(separator: " · ")]
        for entry in article.highlights { lines += format.highlightLines(entry, quoteLimit: Self.quoteLimit) }
        if let summary = summary(article.url) {
            lines.append("Summary: " + ArticleTextStore.wrapped(format.inline(summary), url: article.url, limit: 400)
                .replacingOccurrences(of: "\n", with: " "))
        }
        return lines
    }

    static func key(_ url: String) -> String { URL(string: url)?.readerCanonicalKey ?? url }
}
