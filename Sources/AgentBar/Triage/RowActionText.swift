import Foundation

/// Plain-English wording for the row buttons and their notices. Pure.
enum RowActionText {
    private static let refusalPrefix = "refused:"

    /// The dashboard's reason, tidied for a row: no "refused:" prefix, "·"
    /// separators as commas, first letter capitalised, no trailing full stop.
    /// Nil when nothing readable is left.
    static func plainReason(_ raw: String?) -> String? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if text.lowercased().hasPrefix(refusalPrefix) { text = String(text.dropFirst(refusalPrefix.count)) }
        text = text.replacingOccurrences(of: " · ", with: ", ")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        guard let first = text.first else { return nil }
        return first.uppercased() + text.dropFirst()
    }

    /// The row's detail line while it waits for the second press.
    static func confirmPrompt(kind: SessionActionKind, reason: String) -> String {
        let action = kind == .stop ? "Stops the agent" : "Closes the pane"
        guard let stake = plainReason(reason) else { return "\(action). Confirm?" }
        return "\(stake). Confirm?"
    }

    /// The button's label in its current state.
    static func title(of button: RowButton, state: RowActionState?) -> String {
        guard let state, state.button == button else { return button.title }
        switch state {
        case .busy: return button == .closePane ? "Closing…" : "Stopping…"
        case .confirming: return "Confirm"
        case .completed: return button == .closePane ? "Closed" : "Stopped"
        }
    }

    /// Footer text for a failed press.
    static func failureNotice(kind: SessionActionKind, message: String) -> String {
        let what = kind == .stop ? "finish that agent" : "close that pane"
        return "Couldn't \(what): \(plainReason(message) ?? "the dashboard refused.")"
    }
}
