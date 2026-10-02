import Foundation
import NaturalLanguage

/// Turns a `ReaderArticle`'s sanitised HTML into plain-text chunks for speech,
/// one per paragraph-level block (paragraph, heading, list item, quote...).
/// Pure and synchronous so it is unit-testable without a synthesizer.
enum ReadAloudText {
    /// Chunks longer than this are split at sentence ends so a single utterance
    /// stays short enough to pause/resume cleanly.
    static let maxChunkLength = 1_500

    /// Title first, then each body block in reading order. Empty blocks dropped.
    static func chunks(for article: ReaderArticle) -> [String] {
        let title = normalizedWhitespace(article.title)
        let body = paragraphs(fromHTML: article.content).flatMap(splitLongParagraph)
        return (title.isEmpty ? [] : [title]) + body
    }

    /// Splits HTML on block boundaries, strips remaining tags and decodes entities.
    static func paragraphs(fromHTML html: String) -> [String] {
        var text = html
        // Non-spoken content: scripts, styles, code blocks, inline SVG, comments.
        for pattern in ["<(script|style|pre|svg)\\b[^>]*>[\\s\\S]*?</\\1>", "<!--[\\s\\S]*?-->"] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        let blockBoundary = "<br\\s*/?>|</?(p|div|h[1-6]|li|ul|ol|blockquote|section|article|figcaption|tr|header|footer)\\b[^>]*>"
        text = text.replacingOccurrences(of: blockBoundary, with: "\n\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return text
            .components(separatedBy: "\n\n")
            .map { normalizedWhitespace(decodeEntities($0)) }
            .filter { !$0.isEmpty }
    }

    /// Keeps chunks under `maxChunkLength` by packing whole sentences.
    static func splitLongParagraph(_ paragraph: String) -> [String] {
        guard paragraph.count > maxChunkLength else { return [paragraph] }
        var chunks: [String] = []
        var current = ""
        paragraph.enumerateSubstrings(in: paragraph.startIndex..., options: .bySentences) { sentence, _, _, _ in
            guard let sentence else { return }
            if !current.isEmpty, current.count + sentence.count > maxChunkLength {
                chunks.append(normalizedWhitespace(current))
                current = ""
            }
            current += sentence + " "
        }
        let tail = normalizedWhitespace(current)
        if !tail.isEmpty { chunks.append(tail) }
        return chunks
    }

    /// BCP-47 language code (e.g. "en", "vi") of the text, or nil when unsure.
    static func dominantLanguage(of chunks: [String]) -> String? {
        let sample = String(chunks.joined(separator: " ").prefix(2_000))
        guard !sample.isEmpty else { return nil }
        return NLLanguageRecognizer.dominantLanguage(for: sample)?.rawValue
    }

    // MARK: - Helpers

    private static func normalizedWhitespace(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "mdash": "—", "ndash": "–", "hellip": "…", "rsquo": "’", "lsquo": "‘",
        "rdquo": "”", "ldquo": "“",
    ]

    private static let entityPattern = try! NSRegularExpression(pattern: "&(#[xX]?[0-9a-fA-F]+|[a-zA-Z]+);")

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let ns = text as NSString
        var result = ""
        var cursor = 0
        for match in entityPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += decodedEntity(ns.substring(with: match.range(at: 1))) ?? ns.substring(with: match.range)
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }

    private static func decodedEntity(_ name: String) -> String? {
        guard name.hasPrefix("#") else { return namedEntities[name.lowercased()] }
        let isHex = name.dropFirst().first.map { $0 == "x" || $0 == "X" } ?? false
        let digits = name.dropFirst(isHex ? 2 : 1)
        guard let code = UInt32(digits, radix: isHex ? 16 : 10), let scalar = Unicode.Scalar(code) else { return nil }
        return String(Character(scalar))
    }
}
