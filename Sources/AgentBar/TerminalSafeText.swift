import Foundation

/// Text on its way into an agent's terminal. A control character in it is a keystroke there (ESC backs out,
/// Ctrl-C interrupts, Tab completes), so nothing of the kind is ever typed: pasted text can carry them unseen.
enum TerminalSafeText {
    /// `text` with every tab turned into a space and every other control character dropped
    /// (line breaks are the caller's business: the callers collapse them to spaces).
    static func withoutControlCharacters(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar == "\t" { scalars.append(" ") }
            else if scalar.properties.generalCategory != .control || scalar.properties.isWhitespace { scalars.append(scalar) }
        }
        return String(scalars)
    }
}
