import Foundation

/// The summary comes back as light markdown (bold, bullets, indented sub-bullets). iOS renders
/// inline markdown but not block structure, so lines are split into blocks here; pure, unit-tested.
enum SummaryMarkdown {
    enum Block: Equatable {
        case heading(String)
        case paragraph(String)
        case bullet(level: Int, text: String)
    }

    static func blocks(_ markdown: String) -> [Block] {
        markdown.components(separatedBy: .newlines).compactMap { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            if trimmed.hasPrefix("#") {
                let text = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                return text.isEmpty ? nil : .heading(text)
            }
            for marker in ["- ", "* ", "• "] where trimmed.hasPrefix(marker) {
                let indent = raw.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
                let text = String(trimmed.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
                return text.isEmpty ? nil : .bullet(level: min(indent / 2, 3), text: text)
            }
            return .paragraph(trimmed)
        }
    }

    /// Inline bold/italic/links; falls back to the plain text when the markdown is malformed.
    static func attributed(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

/// Summary text is drawn at the reader's own text size (More ▸ the reader's Reading Settings), so a
/// summary never looks smaller than the article. Pure, unit-tested.
enum SummaryTextStyle {
    struct Sizes: Equatable {
        let body: CGFloat
        let bullet: CGFloat
        let heading: CGFloat
    }

    static func sizes(readerFontSize: Int) -> Sizes {
        let base = CGFloat(readerFontSize)
        return Sizes(body: base, bullet: base, heading: (base * 1.1).rounded())
    }
}
