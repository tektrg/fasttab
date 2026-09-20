import Foundation

/// One block of an agent's message, as the card draws it. Inline styling (bold,
/// italic, code, links) stays inside the text as markdown; see `MarkdownInline`.
enum MarkdownBlock: Equatable, Sendable {
    enum ListMarker: Equatable, Sendable {
        case bullet
        case number(Int)
    }

    case heading(level: Int, text: String)
    /// Consecutive lines; their line breaks are kept (`\n`).
    case paragraph(String)
    /// One list item. Nesting is only its `depth` (0 = top level); a continuation line joins `text` after a `\n`.
    case listItem(depth: Int, marker: ListMarker, text: String)
    case codeBlock(language: String?, code: String)
    case quote([MarkdownBlock])
    /// Every row has exactly `header.count` cells (short rows padded, long ones cut).
    case table(header: [String], rows: [[String]])
    case rule
}
