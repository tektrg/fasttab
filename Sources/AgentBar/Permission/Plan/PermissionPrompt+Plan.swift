import Foundation

/// What AgentBar decides about a plan-approval box's options. It never hard-codes the wording it
/// shows (the card draws `options` verbatim); it only recognises the two kinds of row that need
/// special handling, so an unrecognised layout degrades to plain "pick a row" buttons.
extension PermissionPrompt {
    var isPlan: Bool { kind == .plan }

    /// The row that takes typed feedback instead of proceeding. Rule: the first row whose label starts with
    /// "Tell Claude" (the dashboard accepts `text` only on a row saying "Tell Claude what to change"); on a
    /// plan box with no such row, the last row unless it says "Yes" (the box's feedback row has always been
    /// last). If the dashboard does not agree the row takes text, it refuses and the card shows why.
    var feedbackOption: Option? {
        guard isPlan else { return nil }
        if let tell = options.first(where: { $0.label.hasPrefix("Tell Claude") }) { return tell }
        guard let last = options.last, !last.label.hasPrefix("Yes") else { return nil }
        return last
    }

    func isFeedbackOption(_ option: Option) -> Bool { feedbackOption == option }

    /// A row that widens what the agent may do without asking again: it needs a second, explicit press.
    /// Matches the words the box uses ("auto mode", "bypass permissions", the older "auto-accept edits") ignoring case,
    /// hyphens and runs of spaces, so a variant spelling still gets the second press (a miss would send at once).
    static func isPrivilegeChange(_ option: Option) -> Bool {
        let label = normalizedWords(option.label)
        return label.contains("auto mode") || label.contains("auto accept") || label.contains("bypass permissions")
    }

    /// The second-press sentence for a privilege-changing row, naming the change.
    static func privilegeConfirmText(for option: Option) -> String {
        let label = normalizedWords(option.label)
        if label.contains("bypass permissions") { return "This lets the agent bypass permission prompts — press again to confirm" }
        if label.contains("auto accept") { return "This lets the agent edit without asking — press again to confirm" }
        return "This puts the agent in auto mode — press again to confirm"
    }

    /// Lowercase words separated by single spaces ("Auto-accept  Edits" -> "auto accept edits").
    private static func normalizedWords(_ label: String) -> String {
        label.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "-" }).joined(separator: " ")
    }
}
