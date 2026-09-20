import Foundation

/// The plan-approval box Claude's plan mode draws ("Claude has written up a plan and is ready to
/// execute. Would you like to proceed?"): a Swift port of `parse_plan_approval_block` in the
/// dashboard's `classify_pane.py`. Gated on the box's full title sentence and never guessed
/// otherwise; mutually exclusive with the tool-permission box and the question picker by construction.
///
/// Herdr panes are 76 columns wide and the box wraps its own text: the title over two (rarely three)
/// rows, the footer path on a row of its own or split mid-token. This reader joins those rows back
/// (title with single spaces, path with none). The echoed `title` is therefore the joined single-space
/// sentence, which is what a wide drawing gives and what the dashboard compares (`_same_permission`).
extension PanePermissionReader {
    /// A title the wrap spreads over more physical rows than this is not recognised.
    private static let planTitleMaxRows = 3
    /// A footer path the wrap splits over more rows than this (first row included) is not joined.
    private static let planPathMaxRows = 4

    static func planPrompt(in screenLines: [String]) -> PermissionPrompt? {
        let lines = screenLines.suffix(lineWindow).map(rightTrimmed)
        guard let cursorLine = lines.lastIndex(where: { matches(cursorOptionPattern, $0) }) else { return nil }
        let top = lines[...cursorLine].lastIndex(where: hasBorderRun).map { $0 + 1 } ?? 0
        let bottom = lines[(cursorLine + 1)...].firstIndex(where: hasBorderRun) ?? lines.count
        let block = lines[top..<bottom]
        guard !block.contains(where: { $0.contains("☐") || $0.contains("☒") }),
              !block.contains(where: isReviewLine),
              let title = planTitle(in: lines, from: top, to: bottom) else { return nil }
        let afterTitle = title.lastRow + 1
        let options = lines[afterTitle..<bottom].compactMap(option)
        guard options.count >= 2, let cursorIndex = firstNumber(cursorOptionPattern, lines[cursorLine]) else { return nil }
        return PermissionPrompt(
            tool: "ExitPlanMode",
            detail: "",
            title: title.text,
            options: options,
            cursorIndex: cursorIndex,
            kind: .plan,
            planPath: planPath(in: lines, from: afterTitle, to: bottom)
        )
    }

    /// The first run of 1...`planTitleMaxRows` consecutive rows (a blank row included, as `_join_wrapped_lines`
    /// does) that, trimmed, joined with single spaces and with runs of whitespace collapsed, is exactly the
    /// plan title sentence. The smallest join that matches wins; the run must be the whole sentence.
    private static func planTitle(in lines: [String], from top: Int, to bottom: Int) -> (text: String, lastRow: Int)? {
        for first in top..<bottom {
            for count in 1...planTitleMaxRows where first + count <= bottom {
                let joined = lines[first..<(first + count)]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .joined(separator: " ")
                    .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if matches(planTitlePattern, joined) { return (joined, first + count - 1) }
            }
        }
        return nil
    }

    /// The plan file named by the box's footer ("ctrl+g to edit in Vim ·" then the path), nil when there is none
    /// or it cannot be told for sure. A footer row counts only when a blank row precedes it (an option's own
    /// wrapped label never has one), and more than one such row is ambiguous, so nil (never last-match-wins).
    /// The path is whole on the footer row, or the row ends at the "·" and the path follows on the next rows,
    /// joined with no space when the wrap split it mid-token (`.md` only, at most `planPathMaxRows` - 1 rows).
    private static func planPath(in lines: [String], from start: Int, to bottom: Int) -> String? {
        var candidates: [String] = []
        var row = start
        while row < bottom {
            defer { row += 1 }
            guard row >= 1, lines[row - 1].trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if let whole = groups(planFooterPathPattern, lines[row])?.first {
                candidates.append(whole)
            } else if matches(planFooterPrefixPattern, lines[row]) {
                var fragments = ""
                var next = row + 1
                while next < min(bottom, row + planPathMaxRows) {
                    let fragment = lines[next].trimmingCharacters(in: .whitespaces)
                    if fragment.isEmpty || fragment.contains(" ") || matches(chromePattern, fragment) || hasBorderRun(fragment) { break }
                    fragments += fragment
                    next += 1
                    if fragments.hasSuffix(".md") { break }
                }
                if fragments.hasSuffix(".md") {
                    candidates.append(fragments)
                    row = next - 1
                }
            }
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    // `PLAN_APPROVAL_TITLE_RE` (matched against the joined rows), `PLAN_PATH_FOOTER_RE`,
    // `PLAN_PATH_FOOTER_PREFIX_RE` and `CHROME_RE`.
    private static let planTitlePattern = pattern(#"^\s*Claude has written up a plan and is ready to execute\.\s*Would you like to proceed\?\s*$"#)
    private static let planFooterPathPattern = pattern(#"ctrl\+g to edit in Vim\s*·\s*(\S+\.md)\s*$"#)
    private static let planFooterPrefixPattern = pattern(#"ctrl\+g to edit in Vim\s*·\s*$"#)
    private static let chromePattern = pattern(#"^[\s─-╿•■-◿✦✧✎✴⭘●○❯✻✔◼◻☢⏺]*$"#)
}
