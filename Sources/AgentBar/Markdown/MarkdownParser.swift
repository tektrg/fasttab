import Foundation

/// Turns an agent's message into blocks. Not a full CommonMark: it covers what agents write
/// (headings, paragraphs, nested lists, fenced code, quotes, tables, rules) and degrades to
/// plain paragraphs on anything else. Never fails, and bounded: input past `maxCharacters` is
/// cut (the last block says so), and block, table and quote-nesting counts are capped.
enum MarkdownParser {
    static let maxCharacters = 20_000
    static let maxBlocks = 400
    static let maxQuoteDepth = 3
    static let maxTableColumns = 12
    static let maxTableRows = 100
    static let truncationNote = "… (message cut for display)"

    static func parse(_ markdown: String) -> [MarkdownBlock] {
        let isCut = markdown.count > maxCharacters   // count is O(n), fine at this size class
        let text = isCut ? String(markdown.prefix(maxCharacters)) : markdown
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        var blocks = BlockScanner.blocks(in: lines, quoteDepth: 0)
        if blocks.count > maxBlocks { blocks = Array(blocks.prefix(maxBlocks)) + [.paragraph(truncationNote)] }
        else if isCut { blocks.append(.paragraph(truncationNote)) }
        return blocks
    }

    // MARK: - Line classification (also used by tests through `parse`)

    fileprivate static func indentWidth(of line: String) -> Int {
        var width = 0
        for character in line {
            if character == " " { width += 1 } else if character == "\t" { width += 4 } else { break }
        }
        return width
    }

    fileprivate struct Fence {
        let character: Character
        let length: Int
        let language: String?

        init?(trimmedLine: String) {
            guard let first = trimmedLine.first, first == "`" || first == "~" else { return nil }
            let run = trimmedLine.prefix { $0 == first }
            guard run.count >= 3 else { return nil }
            let info = trimmedLine.dropFirst(run.count).trimmingCharacters(in: .whitespaces)
            if first == "`", info.contains("`") { return nil }   // ```code``` on one line is inline code
            character = first
            length = run.count
            let word = info.split(whereSeparator: \.isWhitespace).first.map(String.init)
            language = word
        }

        func closes(_ trimmedLine: String) -> Bool {
            let run = trimmedLine.prefix { $0 == character }
            return run.count >= length && run.count == trimmedLine.count
        }
    }

    fileprivate static func headingParts(of trimmed: String) -> (level: Int, text: String)? {
        let hashes = trimmed.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = trimmed.dropFirst(hashes.count)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text.removeLast() }   // closing hashes: "## Title ##"
        text = text.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (hashes.count, text)
    }

    fileprivate static func isRule(_ trimmed: String) -> Bool {
        guard trimmed.count >= 3, let first = trimmed.first, "-*_".contains(first) else { return false }
        return trimmed.allSatisfy { $0 == first }
    }

    fileprivate static func listItemParts(of line: String) -> (indent: Int, marker: MarkdownBlock.ListMarker, text: String)? {
        let indent = indentWidth(of: line)
        let rest = line.drop { $0 == " " || $0 == "\t" }
        let marker: MarkdownBlock.ListMarker
        let afterMarker: Substring
        if let first = rest.first, "-*+".contains(first) {
            marker = .bullet
            afterMarker = rest.dropFirst()
        } else {
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            guard (1...9).contains(digits.count), let number = Int(digits) else { return nil }
            let punctuation = rest.dropFirst(digits.count)
            guard let mark = punctuation.first, mark == "." || mark == ")" else { return nil }
            marker = .number(number)
            afterMarker = punctuation.dropFirst()
        }
        guard afterMarker.first == " " || afterMarker.first == "\t" else { return nil }
        var text = afterMarker.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("[ ] ") { text = "☐ " + String(text.dropFirst(4)) }
        else if text.hasPrefix("[x] ") || text.hasPrefix("[X] ") { text = "☑ " + String(text.dropFirst(4)) }
        return (indent, marker, text)
    }

    /// Cells of a `| a | b |` row; `\|` stays inside its cell.
    fileprivate static func tableCells(of line: String) -> [String] {
        var body = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\|", with: "\u{1}")
        if body.hasPrefix("|") { body.removeFirst() }
        if body.hasSuffix("|") { body.removeLast() }
        return body.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.replacingOccurrences(of: "\u{1}", with: "|").trimmingCharacters(in: .whitespaces) }
    }

    fileprivate static func isTableDelimiter(_ line: String, columns: Int) -> Bool {
        guard line.contains("-") else { return false }
        let cells = tableCells(of: line)
        guard cells.count == columns else { return false }
        return cells.allSatisfy { cell in
            let core = cell.drop { $0 == ":" }.reversed().drop { $0 == ":" }
            return !core.isEmpty && core.allSatisfy { $0 == "-" } && cell.count - core.count <= 2
        }
    }
}

/// One pass over a run of lines, building blocks. A value type so a quote can scan its own lines.
private struct BlockScanner {
    let lines: [String]
    let quoteDepth: Int
    private var index = 0
    private var blocks: [MarkdownBlock] = []
    private var paragraph: [String] = []
    /// Indent widths of the open list levels, outermost first.
    private var listIndents: [Int] = []
    /// The previous line was a list item's text, so an indented line after it continues it.
    private var canContinueListItem = false

    init(lines: [String], quoteDepth: Int) {
        self.lines = lines
        self.quoteDepth = quoteDepth
    }

    static func blocks(in lines: [String], quoteDepth: Int) -> [MarkdownBlock] {
        var scanner = BlockScanner(lines: lines, quoteDepth: quoteDepth)
        return scanner.run()
    }

    private mutating func run() -> [MarkdownBlock] {
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flushParagraph()
                canContinueListItem = false
                index += 1
            } else if let fence = MarkdownParser.Fence(trimmedLine: trimmed) {
                takeCodeBlock(opening: fence, indent: MarkdownParser.indentWidth(of: line))
            } else if let heading = MarkdownParser.headingParts(of: trimmed) {
                takeBlock(.heading(level: heading.level, text: heading.text))
            } else if MarkdownParser.isRule(trimmed) {
                takeBlock(.rule)
            } else if trimmed.hasPrefix(">") {
                takeQuote()
            } else if let table = tableStarting(at: index) {
                takeBlock(table.block, consuming: table.lineCount)
            } else if let item = MarkdownParser.listItemParts(of: line) {
                takeListItem(item)
            } else {
                takeTextLine(line, trimmed: trimmed)
            }
        }
        flushParagraph()
        return blocks
    }

    // MARK: - Block starts

    /// A block that ends any paragraph and any open list.
    private mutating func takeBlock(_ block: MarkdownBlock, consuming lineCount: Int = 1) {
        flushParagraph()
        blocks.append(block)
        listIndents = []
        canContinueListItem = false
        index += lineCount
    }

    private mutating func takeCodeBlock(opening fence: MarkdownParser.Fence, indent: Int) {
        flushParagraph()
        index += 1
        var code: [String] = []
        while index < lines.count {   // an unterminated fence runs to the end of the message
            let line = lines[index]
            index += 1
            if fence.closes(line.trimmingCharacters(in: .whitespaces)) { break }
            code.append(String(line.dropFirst(min(indent, MarkdownParser.indentWidth(of: line)))))
        }
        blocks.append(.codeBlock(language: fence.language, code: code.joined(separator: "\n")))
        canContinueListItem = false   // the list's levels stay: items after the code carry on
    }

    private mutating func takeQuote() {
        var inner: [String] = []
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(">") else { break }
            let rest = trimmed.dropFirst()
            inner.append(String(rest.first == " " ? rest.dropFirst() : rest))
            index += 1
        }
        let content = quoteDepth < MarkdownParser.maxQuoteDepth
            ? BlockScanner.blocks(in: inner, quoteDepth: quoteDepth + 1)
            : [.paragraph(inner.joined(separator: "\n"))]
        takeBlock(.quote(content), consuming: 0)
    }

    private func tableStarting(at start: Int) -> (block: MarkdownBlock, lineCount: Int)? {
        guard lines[start].contains("|"), start + 1 < lines.count else { return nil }
        let headerCells = MarkdownParser.tableCells(of: lines[start])
        guard MarkdownParser.isTableDelimiter(lines[start + 1], columns: headerCells.count) else { return nil }
        let header = Array(headerCells.prefix(MarkdownParser.maxTableColumns))
        var rows: [[String]] = []
        var next = start + 2
        while next < lines.count, rows.count < MarkdownParser.maxTableRows,
              !lines[next].trimmingCharacters(in: .whitespaces).isEmpty, lines[next].contains("|") {
            let cells = MarkdownParser.tableCells(of: lines[next])
            rows.append((0..<header.count).map { $0 < cells.count ? cells[$0] : "" })
            next += 1
        }
        return (.table(header: header, rows: rows), next - start)
    }

    private mutating func takeListItem(_ item: (indent: Int, marker: MarkdownBlock.ListMarker, text: String)) {
        flushParagraph()
        while let last = listIndents.last, item.indent < last { listIndents.removeLast() }
        if listIndents.last.map({ item.indent > $0 }) ?? true { listIndents.append(item.indent) }
        blocks.append(.listItem(depth: listIndents.count - 1, marker: item.marker, text: item.text))
        canContinueListItem = true
        index += 1
    }

    private mutating func takeTextLine(_ line: String, trimmed: String) {
        defer { index += 1 }
        if canContinueListItem, paragraph.isEmpty, MarkdownParser.indentWidth(of: line) > 0,
           case .listItem(let depth, let marker, let text)? = blocks.last {
            blocks[blocks.count - 1] = .listItem(depth: depth, marker: marker, text: text + "\n" + trimmed)
            return
        }
        if paragraph.isEmpty { listIndents = [] }
        canContinueListItem = false
        paragraph.append(trimmed)
    }

    private mutating func flushParagraph() {
        guard !paragraph.isEmpty else { return }
        blocks.append(.paragraph(paragraph.joined(separator: "\n")))
        paragraph = []
    }
}
