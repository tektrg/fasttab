import Foundation

/// Makes raw pane text safe and compact to show in the peek: no terminal
/// escape sequences, no control characters, bounded line length, and only the
/// tail of the screen (the newest output is at the bottom). Pure.
enum PaneScreenText {
    /// Newest lines kept; the view shows as many of them as fit.
    static let maxLineCount = 40
    /// Longer lines are cut with an ellipsis (the view clips to the panel width anyway).
    static let maxLineLength = 160
    private static let spacesPerTab = 4

    /// Terminal UIs pad with long runs of spaces (right-aligned status text);
    /// the view truncates each line, so a long gap would push that text out of
    /// sight. Shorten gaps between words, leaving indentation alone.
    private static let interiorGapPattern = "(?<=\\S) {6,}(?=\\S)"
    private static let interiorGapReplacement = "    "

    private static let escapeSequencePatterns = [
        "\\u001B\\][^\\u0007\\u001B]*(\\u0007|\\u001B\\\\)",   // OSC (window titles, hyperlinks)
        "\\u001B\\[[0-?]*[ -/]*[@-~]",                         // CSI (colours, cursor moves)
        "\\u001B[@-Z\\\\-_]"                                   // any other two-character escape
    ]

    static func cleaned(_ rawLines: [String]) -> [String] {
        var lines = rawLines.map(cleanedLine)
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        return Array(lines.suffix(maxLineCount))
    }

    private static func cleanedLine(_ raw: String) -> String {
        var text = raw
        for pattern in escapeSequencePatterns {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        var visible = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar == "\t" {
                visible.append(contentsOf: String(repeating: " ", count: spacesPerTab).unicodeScalars)
            } else if !isUnsafe(scalar) {
                visible.append(scalar)
            }
        }
        let trimmed = String(visible)
            .replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            .replacingOccurrences(of: interiorGapPattern, with: interiorGapReplacement, options: .regularExpression)
        guard trimmed.count > maxLineLength else { return trimmed }
        return String(trimmed.prefix(maxLineLength - 1)) + "…"
    }

    /// Control characters and the bidirectional overrides that can reorder text.
    private static func isUnsafe(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.generalCategory == .control
            || (0x202A...0x202E).contains(scalar.value)
            || (0x2066...0x2069).contains(scalar.value)
    }
}
