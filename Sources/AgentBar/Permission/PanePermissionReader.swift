import Foundation

/// Reads the permission box open in a pane from the pane's screen lines, the way the
/// dashboard does before it presses a key (`parse_permission_block` in its
/// `classify_pane.py`). The dashboard refuses a decision unless the box it reads now
/// equals the one sent, so the card sends what THIS reader finds on a fresh, unwrapped
/// read of the same 100 lines the dashboard reads. The status feed's copy cannot be
/// trusted for that: it reads the wrapped screen, where a long command breaks over
/// several rows and no receipt line matches.
///
/// If this ever drifts from the dashboard's parser the worst case is a refusal
/// ("permission prompt changed or gone"): nothing is typed on a mismatch.
enum PanePermissionReader {
    /// The dashboard reads the last 100 lines.
    static let lineWindow = 100
    /// How far above the title the `⏺ Tool(args)` receipt may sit (an edit box draws its header and diff between).
    static let receiptLookback = 60
    /// How many diff rows an edit box's detail carries; the rest is noted as truncated.
    static let diffExcerptMaxLines = 20
    private static let minimumBorderRun = 20

    /// The permission box open on the screen, whichever kind: a tool call, else a plan-approval box
    /// (`parse_permission_or_plan_block`). The two cannot both match: their titles are disjoint.
    static func prompt(in screenLines: [String]) -> PermissionPrompt? {
        toolPrompt(in: screenLines) ?? planPrompt(in: screenLines)
    }

    /// A tool-call permission box (`parse_permission_block`).
    static func toolPrompt(in screenLines: [String]) -> PermissionPrompt? {
        let lines = screenLines.suffix(lineWindow).map(rightTrimmed)
        guard let cursorLine = lines.lastIndex(where: { matches(cursorOptionPattern, $0) }) else { return nil }
        let top = lines[...cursorLine].lastIndex(where: hasBorderRun).map { $0 + 1 } ?? 0
        let bottom = lines[(cursorLine + 1)...].firstIndex(where: hasBorderRun) ?? lines.count
        let block = lines[top..<bottom]
        guard !block.contains(where: { $0.contains("☐") || $0.contains("☒") }),
              !block.contains(where: isReviewLine),
              let titleLine = (top..<bottom).first(where: { matches(titlePattern, lines[$0]) }) else { return nil }
        let options = lines[(titleLine + 1)..<bottom].compactMap(option)
        guard options.count >= 2, let cursorIndex = firstNumber(cursorOptionPattern, lines[cursorLine]) else { return nil }
        guard let receipt = receiptAndDetail(in: lines, titleLine: titleLine) else { return nil }
        return PermissionPrompt(
            tool: receipt.tool,
            detail: receipt.detail,
            title: lines[titleLine].trimmingCharacters(in: .whitespacesAndNewlines),
            options: options,
            cursorIndex: cursorIndex
        )
    }

    /// The `⏺ Tool(args)` receipt above the title, and for an edit box the diff excerpt drawn between
    /// its own borders (appended to the detail, one row per line). Mirrors `_permission_receipt_and_diff`.
    ///
    /// The walk goes up from the title for at most `receiptLookback` lines. It stops at a "wall" (another
    /// prompt's title, cursor or review marker) until it has crossed the first real border row: from there
    /// up to the receipt is this box's own header and diff, arbitrary file text that may look like a wall.
    private static func receiptAndDetail(in lines: [String], titleLine: Int) -> (tool: String, detail: String)? {
        var receiptLine: Int?
        var found: (tool: String, detail: String)?
        let floor = max(-1, titleLine - 1 - receiptLookback)
        var insideBorderedPanel = false
        for line in stride(from: titleLine - 1, to: floor, by: -1) {
            if let groups = groups(receiptPattern, lines[line]), groups.count == 2 {
                receiptLine = line
                found = (groups[0], groups[1].trimmingCharacters(in: .whitespacesAndNewlines))
                break
            }
            if isBorderRow(lines[line]) {
                insideBorderedPanel = true
                continue
            }
            if !insideBorderedPanel, isWall(lines[line]) { break }
        }
        guard let receiptLine, var result = found else { return nil }
        let borders = ((receiptLine + 1)..<titleLine).filter { isBorderRow(lines[$0]) }
        if borders.count >= 2 {
            let diff = Array(lines[(borders[borders.count - 2] + 1)..<borders[borders.count - 1]])
            if !diff.isEmpty {
                let shown = diff.prefix(diffExcerptMaxLines)
                var excerpt = shown.joined(separator: "\n")
                let extra = diff.count - shown.count
                if extra > 0 { excerpt += "\n… (\(extra) more line(s) truncated)" }
                result.detail += "\n" + excerpt
            }
        }
        return result
    }

    // MARK: - Lines

    static func option(_ line: String) -> PermissionPrompt.Option? {
        guard let parts = groups(optionPattern, line), parts.count == 3, let index = Int(parts[0]) else { return nil }
        return PermissionPrompt.Option(index: index, label: parts[2].trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// A row that is nothing but a border (`PERMISSION_BORDER_LINE_RE`): stricter than `hasBorderRun`,
    /// so a diff line that merely contains border characters is not taken for one.
    private static func isBorderRow(_ line: String) -> Bool {
        let scalars = line.unicodeScalars
        return scalars.count >= minimumBorderRun && scalars.allSatisfy { (0x2500...0x257F).contains($0.value) }
    }

    /// Another prompt's chrome (`_PERMISSION_RECEIPT_WALLS`).
    private static func isWall(_ line: String) -> Bool {
        matches(titlePattern, line) || line.contains("☐") || line.contains("☒") || matches(cursorOptionPattern, line)
            || isReviewLine(line) || matches(submitRowPattern, line)
    }

    static func isReviewLine(_ line: String) -> Bool {
        line.contains("Review your answers") || line.contains("Ready to submit your answers?") || line.contains("Submit answers")
    }

    static func hasBorderRun(_ line: String) -> Bool {
        var run = 0
        for scalar in line.unicodeScalars {
            run = (0x2500...0x257F).contains(scalar.value) ? run + 1 : 0
            if run >= minimumBorderRun { return true }
        }
        return false
    }

    static func rightTrimmed(_ line: String) -> String {
        var end = line.endIndex
        while end > line.startIndex, line[line.index(before: end)].isWhitespace { end = line.index(before: end) }
        return String(line[..<end])
    }

    // MARK: - Patterns (the dashboard's own regular expressions)

    static let cursorOptionPattern = pattern(#"^\s*❯\s*(\d+)\.\s+"#)
    private static let optionPattern = pattern(#"^\s*(?:❯\s*)?(\d+)\.\s+(?:\[\s*([✔xX]?)\s*\]\s+)?(\S.*\S|\S)\s*$"#)
    private static let titlePattern = pattern(#"^\s*(Do you want to proceed\?|Would you like to proceed\?|Do you want to make this edit to .+\?)\s*$"#)
    private static let submitRowPattern = pattern(#"^\s*(?:❯\s*)?(?:Submit|Next)\s*$"#)
    private static let receiptPattern = pattern(#"^\s*⏺\s*([A-Za-z]\w*)\((.*)\)\s*$"#)

    /// Nil only for a pattern that does not compile (a mistake the tests catch): it then matches nothing.
    static func pattern(_ source: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: source)
    }

    static func matches(_ expression: NSRegularExpression?, _ text: String) -> Bool {
        expression?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func groups(_ expression: NSRegularExpression?, _ text: String) -> [String]? {
        guard let match = expression?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).map { group in
            Range(match.range(at: group), in: text).map { String(text[$0]) } ?? ""
        }
    }

    static func firstNumber(_ expression: NSRegularExpression?, _ text: String) -> Int? {
        groups(expression, text)?.first.flatMap { Int($0) }
    }
}
