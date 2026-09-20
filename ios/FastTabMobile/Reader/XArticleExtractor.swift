import Foundation

/// Fetches and renders X "Articles" (long-form posts).
///
/// An Article post's own text is only a `t.co` link, so oEmbed (tweet text) yields nothing
/// readable, and the article body is behind X's login wall in a web view. The public
/// `api.fxtwitter.com` mirror exposes the body as Draft.js blocks, which are rendered here.
/// This is the ONLY third-party call in the reader; it is made only for Article posts
/// (`/article/` URLs, or `/status/` posts whose text is just a link).
enum XArticleExtractor {

    // MARK: - URL parsing

    /// Returns `(handle, statusID)` for `x.com/<handle>/status/<id>` and `x.com/<handle>/article/<id>`.
    /// `x.com/i/article/<id>` is not supported: that ID is the article's own, not a post ID.
    static func postReference(from url: URL) -> (handle: String, id: String)? {
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 3,
              parts[0] != "i",
              parts[1] == "status" || parts[1] == "article",
              parts[2].allSatisfy(\.isNumber) else { return nil }
        return (parts[0], parts[2])
    }

    static func isArticleURL(_ url: URL) -> Bool {
        guard ReaderExtractor.isTwitterURL(url) else { return false }
        return url.path.split(separator: "/").map(String.init).dropFirst().first == "article"
    }

    /// True when oEmbed text is nothing but a `t.co` link — the signature of an Article post.
    static func isLinkOnly(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return false }
        return trimmed.hasPrefix("https://t.co/") || trimmed.hasPrefix("http://t.co/")
    }

    // MARK: - Fetch

    static func fetch(url: URL) async -> ReaderArticle? {
        guard let ref = postReference(from: url),
              let apiURL = URL(string: "https://api.fxtwitter.com/\(ref.handle)/status/\(ref.id)") else { return nil }
        var request = URLRequest(url: apiURL)
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return article(fromAPIResponse: json, url: url)
    }

    // MARK: - Parse

    /// Builds a `ReaderArticle` from the fxtwitter response. Returns nil when the post has no
    /// article or the article has no text.
    static func article(fromAPIResponse json: [String: Any], url: URL) -> ReaderArticle? {
        guard let tweet = json["tweet"] as? [String: Any],
              let article = tweet["article"] as? [String: Any],
              let content = article["content"] as? [String: Any],
              let blocks = content["blocks"] as? [[String: Any]] else { return nil }

        let media = mediaURLs(from: article["media_entities"] as? [[String: Any]] ?? [])
        let entities = entityMap(from: content["entityMap"])
        var body = renderBlocks(blocks, entities: entities, media: media)
        guard blocks.contains(where: { !((($0["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)).isEmpty }),
              !body.isEmpty else { return nil }

        if let cover = article["cover_media"] as? [String: Any],
           let src = imageURL(in: cover) {
            body = image(src) + body
        }

        let title = (article["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Article on X"
        let author = tweet["author"] as? [String: Any]
        let name = author?["name"] as? String ?? ""
        let handle = (author?["screen_name"] as? String).map { "@" + $0 } ?? ""
        let byline = [name, handle].filter { !$0.isEmpty }.joined(separator: " ")
        let excerpt = (article["preview_text"] as? String) ?? ""

        return ReaderArticle(
            title: title, byline: byline, siteName: "X",
            content: body, excerpt: excerpt, url: url, extractedAt: Date()
        )
    }

    // MARK: - Draft.js rendering

    private static func entityMap(from raw: Any?) -> [Int: [String: Any]] {
        var map: [Int: [String: Any]] = [:]
        if let list = raw as? [[String: Any]] {            // fxtwitter: [{key, value}]
            for item in list {
                let key = (item["key"] as? String).flatMap(Int.init) ?? (item["key"] as? Int)
                if let key, let value = item["value"] as? [String: Any] { map[key] = value }
            }
        } else if let dict = raw as? [String: Any] {       // classic Draft.js: {"0": {...}}
            for (k, v) in dict { if let key = Int(k), let value = v as? [String: Any] { map[key] = value } }
        }
        return map
    }

    private static func mediaURLs(from entities: [[String: Any]]) -> [String: String] {
        var map: [String: String] = [:]
        for entity in entities {
            let id = (entity["media_id"] as? String) ?? (entity["media_id"] as? Int).map(String.init)
            if let id, let src = imageURL(in: entity) { map[id] = src }
        }
        return map
    }

    private static func imageURL(in mediaEntity: [String: Any]) -> String? {
        let info = mediaEntity["media_info"] as? [String: Any]
        return info?["original_img_url"] as? String
    }

    private static func image(_ src: String) -> String {
        "<p><img src=\"\(ReaderExtractor.htmlEscape(src))\" style=\"max-width:100%; border-radius:12px; margin:12px 0;\"/></p>"
    }

    static func renderBlocks(_ blocks: [[String: Any]], entities: [Int: [String: Any]], media: [String: String]) -> String {
        var html = ""
        var openList: String?   // "ul" / "ol" while inside a list run

        func closeList() {
            if let tag = openList { html += "</\(tag)>"; openList = nil }
        }

        for block in blocks {
            let type = block["type"] as? String ?? "unstyled"
            let text = block["text"] as? String ?? ""

            if type == "unordered-list-item" || type == "ordered-list-item" {
                let tag = type == "ordered-list-item" ? "ol" : "ul"
                if openList != tag { closeList(); html += "<\(tag)>"; openList = tag }
                html += "<li>\(inlineHTML(text: text, block: block, entities: entities))</li>"
                continue
            }
            closeList()

            switch type {
            case "atomic":
                html += atomicHTML(block: block, entities: entities, media: media)
            case "header-one", "header-two", "header-three":
                let level = type == "header-three" ? "h3" : "h2"
                html += "<\(level)>\(inlineHTML(text: text, block: block, entities: entities))</\(level)>"
            case "blockquote":
                html += "<blockquote>\(inlineHTML(text: text, block: block, entities: entities))</blockquote>"
            case "code-block":
                html += "<pre>\(ReaderExtractor.htmlEscape(text))</pre>"
            default:
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                html += "<p>\(inlineHTML(text: text, block: block, entities: entities))</p>"
            }
        }
        closeList()
        return html
    }

    private static func atomicHTML(block: [String: Any], entities: [Int: [String: Any]], media: [String: String]) -> String {
        var html = ""
        for range in block["entityRanges"] as? [[String: Any]] ?? [] {
            guard let key = range["key"] as? Int, let entity = entities[key],
                  let data = entity["data"] as? [String: Any] else { continue }
            switch entity["type"] as? String {
            case "MEDIA":
                for item in data["mediaItems"] as? [[String: Any]] ?? [] {
                    let id = (item["mediaId"] as? String) ?? (item["mediaId"] as? Int).map(String.init)
                    if let id, let src = media[id] { html += image(src) }
                }
            case "TWEET":
                if let id = data["tweetId"] as? String {
                    html += "<p><a href=\"https://x.com/i/status/\(id)\">Embedded post on X</a></p>"
                }
            default:
                break
            }
        }
        return html
    }

    /// Escapes `text` and wraps Bold/Italic/Strikethrough/Code ranges and LINK entities.
    /// Draft.js offsets count UTF-16 code units.
    static func inlineHTML(text: String, block: [String: Any], entities: [Int: [String: Any]]) -> String {
        let units = Array(text.utf16)
        var cuts: Set<Int> = [0, units.count]

        struct Span { let start: Int; let end: Int; let open: String; let close: String }
        var spans: [Span] = []

        func add(offset: Int?, length: Int?, open: String, close: String) {
            guard let offset, let length, length > 0, offset >= 0, offset + length <= units.count else { return }
            spans.append(Span(start: offset, end: offset + length, open: open, close: close))
            cuts.insert(offset); cuts.insert(offset + length)
        }

        for r in block["inlineStyleRanges"] as? [[String: Any]] ?? [] {
            let tag: String?
            switch (r["style"] as? String)?.lowercased() {
            case "bold": tag = "strong"
            case "italic": tag = "em"
            case "strikethrough": tag = "s"
            case "code": tag = "code"
            default: tag = nil
            }
            if let tag { add(offset: r["offset"] as? Int, length: r["length"] as? Int, open: "<\(tag)>", close: "</\(tag)>") }
        }
        for r in block["entityRanges"] as? [[String: Any]] ?? [] {
            guard let key = r["key"] as? Int, let entity = entities[key],
                  entity["type"] as? String == "LINK",
                  let href = (entity["data"] as? [String: Any])?["url"] as? String else { continue }
            add(offset: r["offset"] as? Int, length: r["length"] as? Int,
                open: "<a href=\"\(ReaderExtractor.htmlEscape(href))\">", close: "</a>")
        }

        let sorted = cuts.sorted()
        var out = ""
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            let piece = ReaderExtractor.htmlEscape(String(decoding: units[a..<b], as: UTF16.self))
            let active = spans.filter { $0.start <= a && $0.end >= b }
            out += active.map(\.open).joined() + piece + active.reversed().map(\.close).joined()
        }
        return out
    }
}
