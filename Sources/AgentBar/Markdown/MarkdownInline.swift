import Foundation

/// The inline half of markdown (bold, italic, `code`, strikethrough, links) for one block's
/// text. Foundation's parser does the work; this only makes it safe and forgiving.
enum MarkdownInline {
    /// Links that are opened when clicked. Anything else (file paths, `file:`, custom schemes)
    /// keeps its text but is not clickable: an agent's message is not trusted to launch things.
    static let openableSchemes: Set<String> = ["http", "https", "mailto"]

    /// Never fails: text the parser cannot read is shown as it is.
    static func attributed(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,   // keeps the message's own line breaks
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard var result = try? AttributedString(markdown: text, options: options) else { return AttributedString(text) }
        for run in Array(result.runs) {
            guard let link = run.link, !isOpenable(link) else { continue }
            result[run.range].link = nil
        }
        return result
    }

    static func isOpenable(_ url: URL) -> Bool {
        url.scheme.map { openableSchemes.contains($0.lowercased()) } ?? false
    }
}
