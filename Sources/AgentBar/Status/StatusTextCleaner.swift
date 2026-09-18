import Foundation

/// Cleans raw pane text (box-drawing borders, padding, newlines) into a short
/// single line fit for a row. Also drops a bare prompt glyph ("❯").
enum StatusTextCleaner {
    /// classify_pane's placeholder for a pane with nothing readable on it.
    private static let noSignalPlaceholder = "(no readable content)"
    private static let borderCharacters = CharacterSet(charactersIn: "│┃─━┌┐└┘╭╮╰╯❯› ")
        .union(.whitespacesAndNewlines)

    /// One line, borders stripped, whitespace collapsed, capped at `maxLength`
    /// characters (with an ellipsis). Nil when nothing meaningful remains.
    static func singleLine(_ raw: String?, maxLength: Int) -> String? {
        guard let raw else { return nil }
        let interior = raw.components(separatedBy: CharacterSet(charactersIn: "│┃\n\r\t"))
            .flatMap { $0.split(separator: " ", omittingEmptySubsequences: true) }
            .joined(separator: " ")
        let trimmed = interior.trimmingCharacters(in: borderCharacters)
        guard !trimmed.isEmpty, trimmed != noSignalPlaceholder else { return nil }
        guard trimmed.count > maxLength else { return trimmed }
        return String(trimmed.prefix(maxLength - 1)) + "…"
    }
}
