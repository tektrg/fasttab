import Foundation

/// Reads which question a pane's picker is asking (its title and text) from the
/// pane's screen lines, the way the dashboard does before it types an answer.
/// It exists for one reason: the dashboard refuses an answer unless the
/// question sent matches ITS reading of the pane letter for letter, and the
/// copy the status feed carries can differ (see `QuestionIdentity.isSameQuestion`).
/// Mirrors `parse_question_block` in the dashboard's `classify_pane.py` for those
/// two strings only. If this ever drifts the worst case is the old behaviour: the
/// dashboard refuses, and nothing is typed.
enum PaneQuestionReader {
    /// The dashboard reads the last 100 lines.
    static let lineWindow = 100
    private static let minimumBorderRun = 20

    static func identity(in screenLines: [String]) -> QuestionIdentity? {
        let lines = screenLines.suffix(lineWindow).map(rightTrimmed)
        guard let cursorIndex = lines.lastIndex(where: isCursorOptionLine) else { return nil }
        let block = blockAround(cursorIndex, in: lines)
        guard !block.contains(where: isReviewScreenLine),
              let title = block.first(where: hasTitleGlyph).map(cleanedTitle), !title.isEmpty,
              let firstOption = block.firstIndex(where: isOptionLine),
              block.filter(isOptionLine).count >= 2 else { return nil }
        let questionParts = block[..<firstOption].compactMap(questionPart)
        let question = collapsed(questionParts.joined(separator: " "))
        return QuestionIdentity(title: title, question: question.isEmpty ? title : question)
    }

    // MARK: - Block and lines

    /// The lines between the horizontal rules above and below the picker's cursor row.
    private static func blockAround(_ cursorIndex: Int, in lines: [String]) -> ArraySlice<String> {
        let top = lines[...cursorIndex].lastIndex(where: hasBorderRun).map { $0 + 1 } ?? 0
        let bottom = lines[(cursorIndex + 1)...].firstIndex(where: hasBorderRun) ?? lines.count
        return lines[top..<bottom]
    }

    private static func questionPart(_ line: String) -> String? {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !hasTitleGlyph(line), !isChrome(text), !hasBorderRun(text), !isFooter(text) else { return nil }
        return text
    }

    private static func rightTrimmed(_ line: String) -> String {
        var end = line.endIndex
        while end > line.startIndex, line[line.index(before: end)].isWhitespace { end = line.index(before: end) }
        return String(line[..<end])
    }

    private static func cleanedTitle(_ line: String) -> String {
        let chrome = Set("─━│┃┌┐└┘├┤┬┴┼╭╮╰╯←→☐☒✔")
        let stripped = String(line.map { chrome.contains($0) ? " " : $0 })
        return collapsed(stripped.replacingOccurrences(of: "Submit", with: " ").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Runs of two or more whitespace characters become one space.
    private static func collapsed(_ text: String) -> String {
        var result = ""
        var pendingWhitespace = ""
        for character in text {
            if character.isWhitespace {
                pendingWhitespace.append(character)
            } else {
                if !pendingWhitespace.isEmpty { result += pendingWhitespace.count >= 2 ? " " : pendingWhitespace }
                pendingWhitespace = ""
                result.append(character)
            }
        }
        if !pendingWhitespace.isEmpty { result += pendingWhitespace.count >= 2 ? " " : pendingWhitespace }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Line shapes

    private static func hasTitleGlyph(_ line: String) -> Bool { line.contains("☐") || line.contains("☒") }

    private static func hasBorderRun(_ line: String) -> Bool {
        var run = 0
        for scalar in line.unicodeScalars {
            run = (0x2500...0x257F).contains(scalar.value) ? run + 1 : 0
            if run >= minimumBorderRun { return true }
        }
        return false
    }

    /// `❯ 1. Label`: the row the picker's cursor is on.
    private static func isCursorOptionLine(_ line: String) -> Bool {
        let text = line.drop(while: \.isWhitespace)
        guard text.first == "❯" else { return false }
        return numberedRow(text.dropFirst())
    }

    /// `1. Label` or `❯ 1. Label`: any option row.
    private static func isOptionLine(_ line: String) -> Bool {
        var text = line.drop(while: \.isWhitespace)
        if text.first == "❯" { text = text.dropFirst() }
        return numberedRow(text)
    }

    private static func numberedRow(_ text: Substring) -> Bool {
        let rest = text.drop(while: \.isWhitespace)
        let digits = rest.prefix(while: \.isASCII).prefix(while: \.isNumber)
        guard !digits.isEmpty else { return false }
        let afterDigits = rest.dropFirst(digits.count)
        guard afterDigits.first == "." else { return false }
        let label = afterDigits.dropFirst()
        return label.first?.isWhitespace == true && !label.allSatisfy(\.isWhitespace)
    }

    private static func isReviewScreenLine(_ line: String) -> Bool {
        line.contains("Review your answers") || line.contains("Ready to submit your answers?") || line.contains("Submit answers")
    }

    private static func isChrome(_ text: String) -> Bool {
        let extras: Set<UInt32> = [0x2022, 0x2726, 0x2727, 0x270E, 0x2734, 0x2B58, 0x25CB, 0x276F, 0x273B, 0x2714, 0x2622, 0x23FA]
        return text.unicodeScalars.allSatisfy { scalar in
            scalar.properties.isWhitespace || (0x2500...0x257F).contains(scalar.value)
                || (0x25A0...0x25FF).contains(scalar.value) || extras.contains(scalar.value)
        }
    }

    private static let footerPhrases = [
        "auto mode on", "for agents", "auto-update failed", "auto-update available", "run claude doctor",
        "shift+tab to cycle", "new task? /clear to save", "disable recaps", "update installed",
        "restart to update", "until auto-compact"
    ]
    private static let footerPatterns = [#"\d+%\s*context"#, #"for (\d+h\s*)?(\d+m\s*)?\d+s\s*·\s*done\b"#]

    private static func isFooter(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if footerPhrases.contains(where: lowered.contains) { return true }
        return footerPatterns.contains { lowered.range(of: $0, options: .regularExpression) != nil }
    }
}
