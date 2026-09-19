import Foundation

/// What of a typed "Other" answer actually reaches the agent. The dashboard
/// types the text into the picker's one-line free-text row (`herdr pane run`),
/// where a line break would submit the answer mid-text, so it turns every run
/// of whitespace, line breaks included, into one space and caps the length.
/// The card does the same before sending and says so: what is sent is what
/// the user was told.
enum OtherAnswerText {
    /// The dashboard's own cap (`_clean_free_text`).
    static let maximumLength = 500

    /// The text to send; nil when there is nothing to send.
    static func sendable(_ typed: String) -> String? {
        let words = typed.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return nil }
        let joined = words.joined(separator: " ")
        let scalars = joined.unicodeScalars
        guard scalars.count > maximumLength else { return joined }
        return String(String.UnicodeScalarView(scalars.prefix(maximumLength)))
    }

    /// A sentence for the card when sending will change the text; nil when it goes as typed.
    static func note(for typed: String) -> String? {
        guard let sent = sendable(typed) else { return nil }
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if sent.unicodeScalars.count == maximumLength, trimmed.unicodeScalars.count > maximumLength {
            return "Only the first \(maximumLength) characters are sent."
        }
        if trimmed.contains(where: \.isNewline) { return "Line breaks are sent as spaces: the agent's answer field is one line." }
        return nil
    }
}
