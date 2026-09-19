import Foundation

/// A question's text as the card shows it: whole. The pane's box borders and
/// stray spacing go, but every word and every paragraph break stays (nothing is
/// cut to a length). Display only: the dashboard is always sent the raw text.
enum QuestionDisplayText {
    static func clean(_ raw: String) -> String {
        var lines: [String] = []
        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = words(in: String(rawLine))
            if line.isEmpty, lines.last?.isEmpty ?? true { continue }   // one blank line at most, none at the start
            lines.append(line)
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// One line with borders removed and runs of spaces made single.
    private static func words(in line: String) -> String {
        let withoutBorders = String(String.UnicodeScalarView(line.unicodeScalars.filter { !(0x2500...0x257F).contains($0.value) }))
        return withoutBorders.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

/// Sizes the card decides without drawing: when the "latest message" needs its Show more.
enum AnswerCardLayout {
    /// Lines of the latest message shown before "Show more".
    static let messageLineLimit = 5
    /// About how many characters of the message fit on a line of the card.
    static let messageCharactersPerLine = 78

    static func estimatedLineCount(of text: String, charactersPerLine: Int = messageCharactersPerLine) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: false).reduce(0) { total, line in
            total + max(1, Int((Double(line.count) / Double(charactersPerLine)).rounded(.up)))
        }
    }

    static func messageNeedsToggle(_ text: String) -> Bool {
        estimatedLineCount(of: text) > messageLineLimit
    }
}
