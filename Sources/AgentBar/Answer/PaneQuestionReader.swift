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

    /// Which question a picker is asking, for any picker that is open: a plain one, one with the cursor
    /// on its exit row, one with options already ticked. Nil only when no picker is on screen.
    static func identity(in screenLines: [String]) -> QuestionIdentity? {
        switch openPickerState(in: screenLines) {
        case .open(let question): question.identity
        case .onExitRow(let identity), .hasTicks(let identity), .unparsed(let identity): identity
        case .review, .none: nil
        }
    }

    /// What the pane's picker is doing, for callers that must tell "answerable" from "someone is already
    /// answering it in the terminal".
    enum PickerState: Equatable, Sendable {
        /// A whole, unanswered picker the panel can answer.
        case open(AnswerableQuestion)
        /// The terminal cursor sits on the exit row (`Submit` / `Next`): no `❯ 1.` line, yet a picker is open.
        case onExitRow(QuestionIdentity)
        /// An option is already ticked (multi-select): the panel would only add ticks, never undo them.
        case hasTicks(QuestionIdentity)
        /// A picker whose rows do not form a clean list (fewer than two, repeated numbers).
        case unparsed(QuestionIdentity)
        /// The form's review screen ("Ready to submit your answers?").
        case review
        case none
    }

    static func openPickerState(in screenLines: [String]) -> PickerState {
        switch scan(screenLines) {
        case .none: return .none
        case .review: return .review
        case .picker(let picker):
            if picker.cursorIsOnExitRow { return .onExitRow(picker.identity) }
            let rows = parsedOptions(in: picker.block)
            if rows.hasTick { return .hasTicks(picker.identity) }
            guard let question = answerable(picker, rows) else { return .unparsed(picker.identity) }
            return .open(question)
        }
    }

    /// The whole picker as the panel can answer it (options with their descriptions), read from
    /// the screen like the dashboard's `parse_question_block`. Nil when there is no picker, or
    /// one the panel leaves to the terminal (an option already ticked, the cursor on the exit row).
    /// `context` (Claude's prose above the box) is not read: the card takes its message from the transcript.
    static func question(in screenLines: [String]) -> AnswerableQuestion? {
        guard case .open(let question) = openPickerState(in: screenLines) else { return nil }
        return question
    }

    private static let descriptionMaxLength = 300

    private struct Rows {
        var options: [AnswerableQuestion.Option] = []
        var isMultiSelect = false
        var hasTick = false
    }

    /// The option rows of the block, down to the exit row: `Chat about this` (drawn after `Submit`)
    /// is never an option.
    private static func parsedOptions(in block: ArraySlice<String>) -> Rows {
        var rows = Rows()
        for line in block {
            if isExitRow(line) { break }
            guard let row = optionRow(line) else {
                if let last = rows.options.last, isDescriptionLine(line) {
                    let bit = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if last.description != bit {
                        rows.options[rows.options.count - 1] = last.describing(String((last.description + " " + bit)
                            .trimmingCharacters(in: .whitespacesAndNewlines).prefix(descriptionMaxLength)))
                    }
                }
                continue
            }
            if row.isChecked { rows.hasTick = true }
            if line.contains("["), line.contains("]") { rows.isMultiSelect = true }
            rows.options.append(.init(index: row.index, label: row.label, description: "", isOther: isOtherLabel(row.label)))
        }
        return rows
    }

    private static func answerable(_ picker: Picker, _ rows: Rows) -> AnswerableQuestion? {
        var options = rows.options
        guard options.count >= AnswerableQuestion.minimumOptionCount, Set(options.map(\.index)).count == options.count else { return nil }
        if !options.contains(where: \.isOther) {
            // The free-text row is always the tool's last one, even once someone typed over its label.
            options[options.count - 1] = options[options.count - 1].markedOther()
        }
        return AnswerableQuestion(
            title: picker.identity.title, question: picker.identity.question,
            isMultiSelect: rows.isMultiSelect, options: options, context: nil
        )
    }

    private struct Picker {
        let block: ArraySlice<String>
        let identity: QuestionIdentity
        let cursorIsOnExitRow: Bool
    }

    private enum Scan {
        case picker(Picker)
        case review
        case none
    }

    /// The bordered block around the last picker's cursor row (an option row or the exit row), and the question it asks.
    private static func scan(_ screenLines: [String]) -> Scan {
        let lines = screenLines.suffix(lineWindow).map(rightTrimmed)
        guard let cursorIndex = lines.lastIndex(where: { isCursorOptionLine($0) || isCursorExitLine($0) }) else { return .none }
        let block = blockAround(cursorIndex, in: lines)
        if block.contains(where: isReviewScreenLine) { return .review }
        guard let title = block.first(where: hasTitleGlyph).map(cleanedTitle), !title.isEmpty,
              let firstOption = block.firstIndex(where: isOptionLine),
              block.filter(isOptionLine).count >= 2 else { return .none }
        let questionParts = block[..<firstOption].compactMap(questionPart)
        let question = collapsed(questionParts.joined(separator: " "))
        let identity = QuestionIdentity(title: title, question: question.isEmpty ? title : question)
        return .picker(Picker(block: block, identity: identity, cursorIsOnExitRow: isCursorExitLine(lines[cursorIndex])))
    }

    // MARK: - Options

    private static let optionRowPattern = try? NSRegularExpression(
        pattern: #"^\s*(?:❯\s*)?(\d+)\.\s+(?:\[\s*([✔xX]?)\s*\]\s+)?(\S.*\S|\S)\s*$"#)
    private static let otherLabelPattern = try? NSRegularExpression(
        pattern: #"^\s*Type something\.?\s*$"#, options: .caseInsensitive)
    private static let submitRowPattern = try? NSRegularExpression(pattern: #"^\s*(?:❯\s*)?(?:Submit|Next)\s*$"#)

    private static func optionRow(_ line: String) -> (index: Int, isChecked: Bool, label: String)? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = optionRowPattern?.firstMatch(in: line, range: range),
              let index = Range(match.range(at: 1), in: line).flatMap({ Int(line[$0]) }),
              let label = Range(match.range(at: 3), in: line).map({ String(line[$0]) }) else { return nil }
        let box = Range(match.range(at: 2), in: line).map { String(line[$0]) } ?? ""
        return (index, !box.isEmpty, label.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// `Submit` or `Next`, with or without the cursor.
    private static func isExitRow(_ line: String) -> Bool {
        submitRowPattern?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    /// `❯ Submit` / `❯ Next`: the cursor is on the exit row, so no option row carries it.
    private static func isCursorExitLine(_ line: String) -> Bool {
        line.drop(while: \.isWhitespace).first == "❯" && isExitRow(line)
    }

    private static func isOtherLabel(_ label: String) -> Bool {
        otherLabelPattern?.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)) != nil
    }

    /// Could this block line be an option's description (`_is_desc_line`)?
    private static func isDescriptionLine(_ line: String) -> Bool {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !hasTitleGlyph(line), !isReviewScreenLine(line), !isChrome(text), !hasBorderRun(text), !isFooter(text)
        else { return false }
        return !isExitRow(line)
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
