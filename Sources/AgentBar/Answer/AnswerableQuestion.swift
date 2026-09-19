import Foundation

/// Which question a picker is asking: the pair the dashboard compares, verbatim,
/// before it types anything into the pane.
struct QuestionIdentity: Hashable, Sendable {
    let title: String
    let question: String
}

/// An AskUserQuestion picker complete enough to answer from the panel.
/// Built only from a fully parsed dashboard question; anything short of that
/// (a preview with no options yet, an odd shape) is not answerable and the
/// row stays read-only. Strings are kept exactly as the dashboard sent them.
struct AnswerableQuestion: Equatable, Sendable {
    struct Option: Equatable, Sendable {
        /// The number the picker shows; a digit key selects it.
        let index: Int
        let label: String
        let description: String
        /// The free-text row: answered by typing, never by selecting.
        let isOther: Bool
    }

    let title: String
    let question: String
    let isMultiSelect: Bool
    let options: [Option]
    /// Claude's last prose above the picker (the dashboard's copy).
    let context: String?

    static let minimumOptionCount = 2

    /// Nil unless `decoded` is a whole, unanswered picker: title, question,
    /// single/multi mode and 2+ options with distinct numbers. A picker that
    /// already has options ticked is left to the terminal: the dashboard can
    /// only add ticks, so the card could not show or undo them faithfully.
    init?(_ decoded: DashboardQuestion?) {
        guard let decoded, let title = decoded.title, let question = decoded.question,
              let isMultiSelect = decoded.multi,
              decoded.options.count >= Self.minimumOptionCount else { return nil }
        var options: [Option] = []
        for raw in decoded.options {
            guard let index = raw.index, let label = raw.label, raw.checked != true else { return nil }
            options.append(Option(index: index, label: label, description: raw.desc ?? "", isOther: raw.other == true))
        }
        guard Set(options.map(\.index)).count == options.count else { return nil }
        self.title = title
        self.question = question
        self.isMultiSelect = isMultiSelect
        self.options = options
        self.context = decoded.context
    }

    /// The whole question as the card shows it: the pane's box borders and stray spacing
    /// are gone, nothing is cut. Only for display; the dashboard is always sent the raw `question`.
    var displayQuestion: String {
        let cleaned = QuestionDisplayText.clean(question)
        return cleaned.isEmpty ? question : cleaned
    }

    var identity: QuestionIdentity {
        QuestionIdentity(title: title, question: question)
    }

    func option(numbered index: Int) -> Option? {
        options.first { $0.index == index }
    }
}
