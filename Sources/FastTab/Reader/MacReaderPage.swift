import FastTabReader
import FastTabSync
import Foundation

/// Builds the reader page: the phone's `reader_template.html` with the article, saved scroll
/// position and the article's synced highlights injected as one JSON block (the template's
/// `<!-- BOOTSTRAP -->` slot). Appearance is left to the template's own light/dark CSS.
enum MacReaderPage {
    struct Highlight: Encodable, Equatable {
        let id: String
        /// The phone's serialized text range (the template re-applies it).
        let range: String
        /// CSS colour.
        let color: String
    }

    private struct Bootstrap: Encodable {
        let title: String
        let byline: String
        let siteName: String
        let content: String
        let initialProgress: Double
        let highlights: [Highlight]
    }

    static func html(template: String, article: MacReaderArticle, initialProgress: Double, highlights: [Highlight]) -> String {
        let bootstrap = Bootstrap(title: article.title, byline: article.byline, siteName: article.siteName,
                                  content: article.content, initialProgress: initialProgress, highlights: highlights)
        let json = (try? JSONEncoder().encode(bootstrap)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        // `</` would end the script element early.
        let block = "<script id=\"fasttab-article-data\" type=\"application/json\">\n"
            + json.replacingOccurrences(of: "</", with: "<\\/") + "\n</script>"
        return template.replacingOccurrences(of: "<!-- BOOTSTRAP -->", with: block)
    }

    /// The phone's highlight colours (`ReaderHighlightColor.cssRGBA`).
    static func cssColor(forHighlightColor name: String) -> String {
        switch name {
        case "green": return "rgba(92, 222, 138, 0.40)"
        case "blue": return "rgba(66, 174, 255, 0.40)"
        case "pink": return "rgba(255, 110, 173, 0.40)"
        default: return "rgba(255, 235, 59, 0.45)"
        }
    }

    /// Highlights made on any device for this article (matched by canonical URL).
    static func highlights(forURL urlString: String, in synced: [SyncedReaderHighlight]) -> [Highlight] {
        guard let key = URL(string: urlString)?.readerCanonicalKey else { return [] }
        return synced.filter { $0.urlKey == key }
            .compactMap { try? JSONDecoder().decode(ReaderHighlightInfo.self, from: $0.payload) }
            .sorted { $0.createdAt < $1.createdAt }
            .map { Highlight(id: $0.id, range: $0.serializedRange, color: cssColor(forHighlightColor: $0.color)) }
    }
}
