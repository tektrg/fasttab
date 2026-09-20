import Foundation

/// One question of a multi-question AskUserQuestion call, as the agent's session
/// transcript records it. The options carry only a label and a description: the
/// terminal's picker numbers them 1...n itself and adds its own free-text row.
struct FormQuestion: Equatable, Sendable {
    struct Option: Equatable, Sendable {
        let label: String
        let description: String
    }

    /// The short tab name ("Done means").
    let header: String
    let question: String
    let isMultiSelect: Bool
    let options: [Option]
}

/// An AskUserQuestion call still waiting for its answer: what the terminal shows
/// as one tab per question. Identified by the transcript's `tool_use` id, which
/// stays the same however the terminal moves between tabs.
struct PendingQuestionForm: Equatable, Sendable {
    /// A form of one question is just the ordinary card.
    static let minimumQuestionCount = 2

    let toolUseId: String
    let questions: [FormQuestion]

    /// The question the terminal is showing, found by its text. Never by tab glyphs: what
    /// the terminal draws next to a tab name is not a reliable sign of anything.
    /// Same wording once spacing and box borders are ignored; failing that, a text that is
    /// the start of exactly one question (a preview cut short).
    func indexOfQuestion(matching paneText: String) -> Int? {
        let wanted = QuestionIdentity.comparable(paneText)
        guard !wanted.isEmpty else { return nil }
        let texts = questions.map { QuestionIdentity.comparable($0.question) }
        if let exact = texts.firstIndex(of: wanted) { return exact }
        let prefixMatches = texts.indices.filter { texts[$0].hasPrefix(wanted) || (!texts[$0].isEmpty && wanted.hasPrefix(texts[$0])) }
        return prefixMatches.count == 1 ? prefixMatches[0] : nil
    }
}
