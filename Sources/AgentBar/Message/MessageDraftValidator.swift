import Foundation

/// What may be typed into an agent from the panel. Pure. The dashboard's message endpoint refuses
/// empty text, any newline, a leading "/" and more than 2000 characters, so the panel decides
/// the same things up front and says why, instead of finding out from a refusal.
enum MessageDraftValidator {
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

    static func check(_ raw: String) -> Verdict {
        let text = sanitized(raw)
        if text.isEmpty { return .empty }
        if text.hasPrefix("/") { return .slashCommand }
        if text.count > maxLength { return .tooLong(over: text.count - maxLength) }
        return .ready(text: text)
    }

    /// True when sending will change the draft (line breaks become spaces): worth telling the user.
    static func sendsWithLineBreaksFlattened(_ raw: String) -> Bool {
        raw.rangeOfCharacter(from: .newlines) != nil
    }

    /// Characters counted toward the cap; what the counter shows.
    static func sentLength(_ raw: String) -> Int { sanitized(raw).count }

    static func showsCounter(for raw: String) -> Bool { sentLength(raw) >= counterFromLength }
}
