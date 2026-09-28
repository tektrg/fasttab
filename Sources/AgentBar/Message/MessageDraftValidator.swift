import Foundation

/// What may be typed into an agent from the panel. Pure. The dashboard's message endpoint refuses
/// empty text, any newline, a leading "/" and more than 2000 characters — except, as of 2026-09-22,
/// exactly `/compact` (bare, or followed by " " and trailing instructions) and exactly `/clear`
/// (bare only — the dashboard's `is_allowed_slash_command` never accepts `/clear` with trailing
/// text, asymmetric with `/compact` on purpose), which both the server and this validator now let
/// through. Every other leading-"/" text is still refused.
enum MessageDraftValidator {
    /// The two bare slash commands the dashboard accepts (`/compactfoo`/`/clearish` do not match:
    /// the command must be the whole word, not merely a prefix).
    private static let allowedSlashCommands = ["/compact", "/clear"]
    /// Only `/compact` also accepts trailing instructions after a space — `/clear` stays bare-only,
    /// mirroring the dashboard's `_ALLOWED_SLASH_PREFIX` exactly (`/clear keep the context` must
    /// still refuse, not silently reset the session with the trailing text discarded).
    private static let allowedSlashCommandsWithTrailingText = ["/compact"]
    /// The dashboard's cap (`validate_message_text`).
    static let maxLength = 2000
    /// The character counter appears from here.
    static let counterFromLength = 1800

    enum Verdict: Equatable, Sendable {
        /// Nothing to send yet (the Send button stays off; no complaint).
        case empty
        /// A leading "/" is a slash command in the agent's input: never sent from here.
        case slashCommand
        case tooLong(over: Int)
        /// `text` is exactly what will be sent.
        case ready(text: String)
    }

    static let slashCommandHint = "Slash commands aren't sent from here. Type it in the terminal."

    static func tooLongHint(over: Int) -> String {
        "\(over) characters over the \(maxLength) limit."
    }

    /// The text as it will be sent: every line break becomes one space (the dashboard refuses
    /// newlines), blank lines and the spaces around a break vanish, ends trimmed, control characters dropped.
    static func sanitized(_ raw: String) -> String {
        TerminalSafeText.withoutControlCharacters(raw).components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// `allowsQuickCommands` false (an inbox route, `MessageRoute`) refuses `/compact` and `/clear` too.
    static func check(_ raw: String, allowsQuickCommands: Bool = true) -> Verdict {
        let text = sanitized(raw)
        if text.isEmpty { return .empty }
        if text.hasPrefix("/"), !(allowsQuickCommands && isAllowedSlashCommand(text)) { return .slashCommand }
        if text.count > maxLength { return .tooLong(over: text.count - maxLength) }
        return .ready(text: text)
    }

    /// `/compact` or `/clear` alone; `/compact` (never `/clear`) also followed by " " and more
    /// text. Never a prefix match, so `/compactfoo` and `/clearish` still count as a plain
    /// (refused) slash command — and `/clear starting fresh` still refuses too, matching the
    /// dashboard's bare-only `/clear`.
    private static func isAllowedSlashCommand(_ text: String) -> Bool {
        if allowedSlashCommands.contains(text) { return true }
        return allowedSlashCommandsWithTrailingText.contains { text.hasPrefix($0 + " ") }
    }

    /// True when sending will change the draft (line breaks become spaces): worth telling the user.
    static func sendsWithLineBreaksFlattened(_ raw: String) -> Bool {
        raw.rangeOfCharacter(from: .newlines) != nil
    }

    /// Characters counted toward the cap; what the counter shows.
    static func sentLength(_ raw: String) -> Int { sanitized(raw).count }

    static func showsCounter(for raw: String) -> Bool { sentLength(raw) >= counterFromLength }
}
