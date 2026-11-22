import Foundation

/// A message-card draft that asks for a dashboard compact job (`/compact`, contract
/// `.claude/compact-api-contract.md` "Composer input rule", identical in the web composer). Pure.
///
/// - Trigger: the draft's first NON-BLANK line, trimmed, is `/compact` or starts with `/compact `
///   (case-sensitive). Leading blank or whitespace-only lines are skipped (QA 2026-11-22: "⏎⏎/compact x"
///   used to flatten into a plain typed `/compact x` with no Sonnet switch). `/compactx`, `/Compact`,
///   or `/compact` after a line with text are not a match (a plain message).
/// - Line 1 after `/compact`, trimmed = `instructions` (empty → nil).
/// - Lines 2…n (Shift+Return newlines) = `followUp`, sent after the compact; every line break
///   becomes one space, the ends are trimmed (empty → nil). Same flattening as a plain message
///   (`MessageDraftValidator.sanitized`): the dashboard refuses newlines in pane text.
struct CompactDraft: Equatable, Sendable {
    static let command = "/compact"

    let instructions: String?
    let followUp: String?

    static func parse(_ draft: String) -> CompactDraft? {
        let lines = draft.components(separatedBy: .newlines)
            .drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let first = lines.first?.trimmingCharacters(in: .whitespaces) else { return nil }
        guard first == command || first.hasPrefix(command + " ") else { return nil }
        let instructions = MessageDraftValidator.sanitized(String(first.dropFirst(command.count)))
        let followUp = MessageDraftValidator.sanitized(lines.dropFirst().joined(separator: "\n"))
        return CompactDraft(
            instructions: instructions.isEmpty ? nil : instructions,
            followUp: followUp.isEmpty ? nil : followUp
        )
    }

    /// Why this draft cannot start a compact; nil when it can. The dashboard caps pane text at
    /// `MessageDraftValidator.maxLength` per piece.
    var refusal: String? {
        for part in [instructions, followUp].compactMap({ $0 }) where part.count > MessageDraftValidator.maxLength {
            return MessageDraftValidator.tooLongHint(over: part.count - MessageDraftValidator.maxLength)
        }
        return nil
    }

    /// The line under the text box while a `/compact` draft is typed.
    var hint: String {
        followUp == nil
            ? "Compacts on Sonnet, then restores the model. ⇧↩ adds a message to send after."
            : "Compacts on Sonnet, restores the model, then sends the lines below as one message."
    }
}
